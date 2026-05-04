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

printf '[unit] dev tracker sync renders auto-managed sections\n'
tracker_copy="$(mktemp)"
rm -f "$tracker_copy"
DEV_TRACKER_PATH="$tracker_copy" bash scripts/sync-dev-tracker.sh
tracker_text="$(python3 - "$tracker_copy" <<'PY'
from pathlib import Path
import sys
print(Path(sys.argv[1]).read_text(encoding='utf-8'))
PY
)"
assert_contains "$tracker_text" '## Current branch' 'Tracker heading should remain present'
# shellcheck disable=SC2016
assert_contains "$tracker_text" 'Branch: `public-clean`' 'Tracker should reflect the current branch'
# shellcheck disable=SC2016
assert_contains "$tracker_text" 'Working version: `0.4.17`' 'Tracker should reflect VERSION'
assert_contains "$tracker_text" 'scripts/sync-dev-tracker.sh' 'Tracker status should mention tracker automation when script itself is modified'
assert_contains "$tracker_text" 'Non-destructive preview on target ODROID M1S' 'Pending device tests should include the standard checklist'

printf '[unit] dev tracker sync records device checks\n'
DEV_TRACKER_PATH="$tracker_copy" bash scripts/sync-dev-tracker.sh --record-device-check preview --record-device-check fresh-install
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
version_backup="$(mktemp)"
cp VERSION "$version_backup"
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
printf '0.4.17-test\n' > VERSION
DEV_TRACKER_PATH="$tracker_copy" TRACKER_SYNC_CONFIG_PATH="$config_copy" bash scripts/sync-dev-tracker.sh
tracker_text="$(python3 - "$tracker_copy" <<'PY'
from pathlib import Path
import sys
print(Path(sys.argv[1]).read_text(encoding='utf-8'))
PY
)"
# shellcheck disable=SC2016
assert_contains "$tracker_text" '- `VERSION`: working version is now `0.4.17-test`.' 'Config include should still keep VERSION status'
# shellcheck disable=SC2016
assert_not_contains "$tracker_text" '- `.tracker-sync.json`: tracker change detection now comes from include/exclude config instead of hardcoded path rules.' 'Config include filter should drop config status lines when config itself is excluded from tracked changes'
# shellcheck disable=SC2016
assert_not_contains "$tracker_text" '- `scripts/sync-dev-tracker.sh`: tracker sync automation now reads `.tracker-sync.json` and rewrites the auto-managed dev-tracker sections from repo state.' 'Config include filter should drop script status lines'
cp "$version_backup" VERSION
rm -f "$config_copy" "$version_backup"

printf '[unit] dev tracker sync records operational events\n'
DEV_TRACKER_PATH="$tracker_copy" bash scripts/sync-dev-tracker.sh --record-operational-event github-issue 'Opened public installer issue #7'
tracker_text="$(python3 - "$tracker_copy" <<'PY'
from pathlib import Path
import sys
print(Path(sys.argv[1]).read_text(encoding='utf-8'))
PY
)"
assert_contains "$tracker_text" '- [github-issue] Opened public installer issue #7' 'Operational event should be appended to historical notes'

rm -f "$tracker_copy"
printf '[unit] dev tracker sync tests complete\n'
