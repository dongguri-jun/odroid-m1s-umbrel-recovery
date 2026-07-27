#!/usr/bin/env bash
set -Eeuo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

assert_contains() {
  local haystack="$1"
  local needle="$2"
  local message="$3"
  if [[ "$haystack" != *"$needle"* ]]; then
    printf '[unit][FAIL] %s: missing %s\n' "$message" "$needle" >&2
    exit 1
  fi
}

assert_not_contains() {
  local haystack="$1"
  local needle="$2"
  local message="$3"
  if [[ "$haystack" == *"$needle"* ]]; then
    printf '[unit][FAIL] %s: unexpectedly found %s\n' "$message" "$needle" >&2
    exit 1
  fi
}

assert_eq() {
  local expected="$1"
  local actual="$2"
  local message="$3"
  if [[ "$expected" != "$actual" ]]; then
    printf '[unit][FAIL] %s: expected %s, got %s\n' "$message" "$expected" "$actual" >&2
    exit 1
  fi
}

printf '[unit] dev tracker sync renders auto-managed sections\n'
tracker_copy="$(mktemp)"
ledger_copy="$(mktemp)"
cleanup() {
  rm -f "$tracker_copy" "$ledger_copy"
}
trap cleanup EXIT
rm -f "$tracker_copy" "$ledger_copy"
changed_sync_json='[{"status":" M","path":"scripts/sync-dev-tracker.sh"}]'
DEV_TRACKER_PATH="$tracker_copy" TASK_LEDGER_PATH="$ledger_copy" TRACKER_CHANGED_JSON_OVERRIDE="$changed_sync_json" bash scripts/sync-dev-tracker.sh
tracker_text="$(python3 - "$tracker_copy" <<'PY'
from pathlib import Path
import sys
print(Path(sys.argv[1]).read_text(encoding='utf-8'))
PY
)"
current_branch="$(GIT_MASTER=1 git branch --show-current)"
current_version="$(<VERSION)"
expected_branch_line="Branch: \`${current_branch}\`"
expected_version_line="Working version: \`${current_version}\`"
assert_contains "$tracker_text" '## Current branch' 'Tracker heading should remain present'
assert_contains "$tracker_text" "$expected_branch_line" 'Tracker should reflect the current branch'
assert_contains "$tracker_text" "$expected_version_line" 'Tracker should reflect VERSION'
assert_contains "$tracker_text" 'scripts/sync-dev-tracker.sh' 'Tracker status should mention tracker automation when script itself is modified'
assert_contains "$tracker_text" 'Non-destructive preview on target ODROID M1S' 'Pending device tests should include the standard checklist'
assert_contains "$tracker_text" '## Local tasks' 'Tracker should spell out the local task section heading'
assert_contains "$tracker_text" '<!-- AUTO:BEGIN local-tasks -->' 'Tracker should create the local task auto block'
assert_eq '600' "$(stat -c '%a' "$tracker_copy")" 'Tracker writes must be private'
[[ ! -e "$ledger_copy" ]] || { printf '[unit][FAIL] Sync must not create or mutate the ledger\n' >&2; exit 1; }

printf '[unit] dev tracker sync records device checks\n'
DEV_TRACKER_PATH="$tracker_copy" TASK_LEDGER_PATH="$ledger_copy" TRACKER_CHANGED_JSON_OVERRIDE="$changed_sync_json" bash scripts/sync-dev-tracker.sh --record-device-check preview --record-device-check fresh-install
tracker_text="$(python3 - "$tracker_copy" <<'PY'
from pathlib import Path
import sys
print(Path(sys.argv[1]).read_text(encoding='utf-8'))
PY
)"
assert_contains "$tracker_text" '- [x] Non-destructive preview on target ODROID M1S' 'Recorded preview check should move to verified'
assert_contains "$tracker_text" '- [x] Destructive fresh install on eMMC-root + NVMe-target' 'Recorded fresh install check should move to verified'
assert_not_contains "$tracker_text" '- [ ] Non-destructive preview on target ODROID M1S' 'Recorded preview check should leave pending list'
assert_not_contains "$tracker_text" '- [ ] Destructive fresh install on eMMC-root + NVMe-target' 'Recorded fresh install check should leave pending list'

printf '[unit] dev tracker sync respects config include filters\n'
config_copy="$(mktemp)"
python3 - ".tracker-sync.json" "$config_copy" <<'PY'
import json
import sys
from pathlib import Path
source = Path(sys.argv[1])
target = Path(sys.argv[2])
config = json.loads(source.read_text(encoding='utf-8'))
config['include_globs'] = ['VERSION']
target.write_text(json.dumps(config, indent=2) + '\n', encoding='utf-8')
PY
changed_version_json='[{"status":" M","path":"VERSION"}]'
DEV_TRACKER_PATH="$tracker_copy" TASK_LEDGER_PATH="$ledger_copy" TRACKER_CHANGED_JSON_OVERRIDE="$changed_version_json" TRACKER_SYNC_CONFIG_PATH="$config_copy" bash scripts/sync-dev-tracker.sh
tracker_text="$(python3 - "$tracker_copy" <<'PY'
from pathlib import Path
import sys
print(Path(sys.argv[1]).read_text(encoding='utf-8'))
PY
)"
# shellcheck disable=SC2016
assert_contains "$tracker_text" "- \`VERSION\`: working version is now \`$current_version\`." 'Config include should still keep VERSION status'
# shellcheck disable=SC2016
assert_not_contains "$tracker_text" '- `.tracker-sync.json`: tracker change detection now comes from include/exclude config instead of hardcoded path rules.' 'Config include filter should drop config status lines when config itself is excluded from tracked changes'
# shellcheck disable=SC2016
assert_not_contains "$tracker_text" '- `scripts/sync-dev-tracker.sh`: tracker sync automation now reads `.tracker-sync.json` and rewrites the auto-managed dev-tracker sections from repo state.' 'Config include filter should drop script status lines'
rm -f "$config_copy"

printf '[unit] dev tracker sync records operational events\n'
DEV_TRACKER_PATH="$tracker_copy" TASK_LEDGER_PATH="$ledger_copy" TRACKER_CHANGED_JSON_OVERRIDE="$changed_sync_json" bash scripts/sync-dev-tracker.sh --record-operational-event github-issue 'Opened public installer issue #7'
tracker_text="$(python3 - "$tracker_copy" <<'PY'
from pathlib import Path
import sys
print(Path(sys.argv[1]).read_text(encoding='utf-8'))
PY
)"
assert_contains "$tracker_text" '- [github-issue] Opened public installer issue #7' 'Operational event should be appended to historical notes'

printf '[unit] dev tracker sync inserts one local task block before historical notes\n'
python3 - "$tracker_copy" <<'PY'
import re
import sys
from pathlib import Path

path = Path(sys.argv[1])
text = path.read_text(encoding="utf-8")
text = re.sub(r'## Local tasks\n<!-- AUTO:BEGIN local-tasks -->.*?<!-- AUTO:END local-tasks -->\n\n', '', text, flags=re.S)
text = text.replace('## Historical notes', '## Manual notes\nKeep this manual section.\n\n## Historical notes')
path.write_text(text, encoding="utf-8")
PY
DEV_TRACKER_PATH="$tracker_copy" TASK_LEDGER_PATH="$ledger_copy" TRACKER_CHANGED_JSON_OVERRIDE="$changed_sync_json" bash scripts/sync-dev-tracker.sh
DEV_TRACKER_PATH="$tracker_copy" TASK_LEDGER_PATH="$ledger_copy" TRACKER_CHANGED_JSON_OVERRIDE="$changed_sync_json" bash scripts/sync-dev-tracker.sh
tracker_text="$(python3 - "$tracker_copy" <<'PY'
from pathlib import Path
import sys
print(Path(sys.argv[1]).read_text(encoding='utf-8'))
PY
)"
local_block_count="$(printf '%s\n' "$tracker_text" | grep -c '<!-- AUTO:BEGIN local-tasks -->')"
assert_eq '1' "$local_block_count" 'Repeated sync must not duplicate the local task block'
assert_contains "$tracker_text" '## Manual notes' 'Existing manual sections must be preserved'
assert_contains "$tracker_text" 'Keep this manual section.' 'Manual tracker content must remain intact'
local_heading_line="$(printf '%s\n' "$tracker_text" | grep -n '^## Local tasks$' | cut -d: -f1)"
historical_heading_line="$(printf '%s\n' "$tracker_text" | grep -n '^## Historical notes$' | cut -d: -f1)"
[[ "$local_heading_line" -lt "$historical_heading_line" ]] || fail 'Local task block must precede historical notes'

printf '[unit] dev tracker sync excludes Python bytecode changes\n'
cache_changed_json='[{"status":"??","path":"scripts/__pycache__/local_task_store.cpython-310.pyc"}]'
cache_tracked_paths="$(DEV_TRACKER_PATH="$tracker_copy" TASK_LEDGER_PATH="$ledger_copy" TRACKER_CHANGED_JSON_OVERRIDE="$cache_changed_json" bash scripts/sync-dev-tracker.sh --print-tracked-paths)"
assert_eq '' "$cache_tracked_paths" 'Python bytecode caches must not be tracked tracker changes'

printf '[unit] dev tracker sync tests complete\n'
