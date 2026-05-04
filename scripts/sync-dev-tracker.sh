#!/usr/bin/env bash
set -Eeuo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

config_path="${TRACKER_SYNC_CONFIG_PATH:-.tracker-sync.json}"
tracker_path_override="${DEV_TRACKER_PATH:-}"
run_local_gates=0
print_tracked_paths=0
declare -a record_device_checks=()
declare -a record_operational_events=()

usage() {
  cat <<'EOF'
Usage: bash scripts/sync-dev-tracker.sh [options]

Sync the auto-managed sections of the dev tracker.

If the local Claude Code PostToolUse hook is installed, tracked code changes schedule
this command automatically after the debounce window. This command remains the manual
fallback when you want to refresh the tracker immediately.

Options:
  --run-local-gates           Run bash scripts/verify-scripts.sh first and record success.
  --record-device-check ID    Mark a configured pending check as completed. Repeatable.
  --record-operational-event CATEGORY MESSAGE
                              Append a dated operational event to Historical notes. Repeatable.
  --print-tracked-paths       Print config-matched changed paths and exit.
  --config PATH               Use a different tracker sync config JSON file.
  --help                      Show this help.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --run-local-gates)
      run_local_gates=1
      shift
      ;;
    --record-device-check)
      [[ $# -ge 2 ]] || { printf 'Missing value for %s\n' "$1" >&2; exit 1; }
      record_device_checks+=("$2")
      shift 2
      ;;
    --record-operational-event)
      [[ $# -ge 3 ]] || { printf 'Missing value for %s\n' "$1" >&2; exit 1; }
      record_operational_events+=("$2\t$3")
      shift 3
      ;;
    --print-tracked-paths)
      print_tracked_paths=1
      shift
      ;;
    --config)
      [[ $# -ge 2 ]] || { printf 'Missing value for %s\n' "$1" >&2; exit 1; }
      config_path="$2"
      shift 2
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      printf 'Unknown option: %s\n' "$1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

[[ -f "$config_path" ]] || {
  printf 'Tracker sync config not found: %s\n' "$config_path" >&2
  exit 1
}

local_gate_verified=0
local_gate_verified_at=""
if [[ "$run_local_gates" -eq 1 ]]; then
  bash scripts/verify-scripts.sh
  local_gate_verified=1
  local_gate_verified_at="$(TZ="Asia/Seoul" date '+%Y-%m-%d %H:%M:%S KST')"
fi

branch_name="$(git branch --show-current 2>/dev/null || true)"
branch_name="${branch_name:-DETACHED_HEAD}"
working_version="$(tr -d '\n' < VERSION)"

release_status="not released"
if git rev-parse -q --verify "refs/tags/v${working_version}" >/dev/null 2>&1; then
  tag_commit="$(git rev-list -n 1 "refs/tags/v${working_version}")"
  head_commit="$(git rev-parse HEAD)"
  if [[ "$tag_commit" == "$head_commit" ]]; then
    release_status="released (tag v${working_version} on HEAD)"
  else
    release_status="tag v${working_version} exists, but HEAD is newer"
  fi
elif [[ -n "$(git status --short)" ]]; then
  release_status="not released (working tree has uncommitted changes)"
fi

changed_json="$(python3 - <<'PY'
import json
import subprocess

lines = subprocess.check_output(['git', 'status', '--porcelain=v1'], text=True).splitlines()
rows = []
for line in lines:
    if not line:
        continue
    status = line[:2]
    path = line[3:]
    if ' -> ' in path:
        path = path.split(' -> ', 1)[1]
    rows.append({'status': status, 'path': path})
print(json.dumps(rows))
PY
)"

record_device_checks_json="$(python3 -c 'import json, sys; print(json.dumps(sys.argv[1:]))' "${record_device_checks[@]}")"
record_operational_events_json="$(python3 -c 'import json, sys; items=[]
for raw in sys.argv[1:]:
    category, message = raw.split("\\t", 1)
    items.append({"category": category, "message": message})
print(json.dumps(items))' "${record_operational_events[@]}")"

CONFIG_PATH="$config_path" \
TRACKER_PATH_OVERRIDE="$tracker_path_override" \
BRANCH_NAME="$branch_name" \
WORKING_VERSION="$working_version" \
RELEASE_STATUS="$release_status" \
LOCAL_GATE_VERIFIED="$local_gate_verified" \
LOCAL_GATE_VERIFIED_AT="$local_gate_verified_at" \
CHANGED_JSON="$changed_json" \
RECORD_DEVICE_CHECKS_JSON="$record_device_checks_json" \
RECORD_OPERATIONAL_EVENTS_JSON="$record_operational_events_json" \
PRINT_TRACKED_PATHS="$print_tracked_paths" \
python3 - <<'PY'
from __future__ import annotations

import json
import os
import re
from datetime import datetime
from fnmatch import fnmatch
from pathlib import Path

CONFIG_PATH = Path(os.environ['CONFIG_PATH'])
config = json.loads(CONFIG_PATH.read_text(encoding='utf-8'))
include_globs = config.get('include_globs', [])
exclude_globs = config.get('exclude_globs', [])
pending_checks = config.get('pending_checks', [])
tracker_path = Path(os.environ['TRACKER_PATH_OVERRIDE'] or config.get('tracker_path', 'docs/dev/dev-tracker.md'))
if not include_globs:
    raise SystemExit('tracker sync config must define include_globs')

for idx, item in enumerate(pending_checks, start=1):
    if 'id' not in item or 'label' not in item:
        raise SystemExit(f'pending_checks[{idx}] must include id and label')

branch_name = os.environ['BRANCH_NAME']
working_version = os.environ['WORKING_VERSION']
release_status = os.environ['RELEASE_STATUS']
local_gate_verified = os.environ['LOCAL_GATE_VERIFIED'] == '1'
local_gate_verified_at = os.environ['LOCAL_GATE_VERIFIED_AT']
changed_rows = json.loads(os.environ['CHANGED_JSON'])
record_device_checks = set(json.loads(os.environ['RECORD_DEVICE_CHECKS_JSON']))
record_operational_events = json.loads(os.environ['RECORD_OPERATIONAL_EVENTS_JSON'])
print_tracked_paths = os.environ['PRINT_TRACKED_PATHS'] == '1'

now_kst = datetime.now().astimezone().strftime('%Y-%m-%d %H:%M:%S %Z')
AUTO_MARKERS = [
    'last-updated',
    'current-branch',
    'current-status',
    'verified',
    'pending-device-tests',
    'release-blockers',
    'next-actions',
]
AUTO_BLOCK_RE = re.compile(
    r'(?P<start><!-- AUTO:BEGIN (?P<name>[a-z\-]+) -->)\n?(?P<body>.*?)(?P<end><!-- AUTO:END (?P=name) -->)',
    re.S,
)

DEVICE_CHECKS = [(item['id'], item['label']) for item in pending_checks]
known_device_ids = {item_id for item_id, _ in DEVICE_CHECKS}
unknown_ids = sorted(record_device_checks - known_device_ids)
if unknown_ids:
    raise SystemExit('Unknown device check id(s): ' + ', '.join(unknown_ids))


def bootstrap_tracker(path: Path) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    device_verified_lines = '\n'.join(f'- [ ] {label}' for _, label in DEVICE_CHECKS) or '- [ ] No pending checks configured'
    pending_lines = '\n'.join(f'- [ ] {label}' for _, label in DEVICE_CHECKS) or '- [x] No remaining checks are configured.'
    text = f"""# Dev Tracker

## Device access convention
- ODROID devices are tracked by MAC address first.
- Connection details live in `docs/ODROID_ACCESS.md`.
- Active ODROID test device:
  - MAC: `00:1E:06:53:68:5D`
  - IP: `192.168.45.71`
  - SSH user: `nordin`
  - Role: ODROID M1S Umbrel installer validation box

## Auto-updated project status
<!-- AUTO:BEGIN last-updated -->
_Last updated: not yet synced_
<!-- AUTO:END last-updated -->

## Current branch
<!-- AUTO:BEGIN current-branch -->
- Branch: `unknown`
- Working version: `unknown`
- Release status: `unknown`
<!-- AUTO:END current-branch -->

## Current status
<!-- AUTO:BEGIN current-status -->
- Tracker sync has not been run yet.
<!-- AUTO:END current-status -->

## Verified
<!-- AUTO:BEGIN verified -->
### Local
- [ ] `bash scripts/verify-scripts.sh`
- Last successful local gate: `not recorded`

### Pending checks
{device_verified_lines}
<!-- AUTO:END verified -->

## Pending device tests
<!-- AUTO:BEGIN pending-device-tests -->
{pending_lines}
<!-- AUTO:END pending-device-tests -->

## Release blockers
<!-- AUTO:BEGIN release-blockers -->
- Run `bash scripts/sync-dev-tracker.sh` after the first implementation pass.
<!-- AUTO:END release-blockers -->

## Next actions
<!-- AUTO:BEGIN next-actions -->
1. Run `bash scripts/sync-dev-tracker.sh --run-local-gates`.
<!-- AUTO:END next-actions -->

## Historical notes
"""
    path.write_text(text, encoding='utf-8')


if not tracker_path.exists():
    bootstrap_tracker(tracker_path)

text = tracker_path.read_text(encoding='utf-8')
for marker in AUTO_MARKERS:
    if f'<!-- AUTO:BEGIN {marker} -->' not in text or f'<!-- AUTO:END {marker} -->' not in text:
        raise SystemExit(f'Missing auto-managed marker block: {marker}')

blocks = {match.group('name'): match.group('body').strip('\n') for match in AUTO_BLOCK_RE.finditer(text)}
if 'Historical notes' not in text:
    raise SystemExit('dev tracker must preserve a manual historical notes section')


def parse_checked_items(block: str) -> set[str]:
    checked = set()
    for line in block.splitlines():
        match = re.match(r'- \[x\] (.+)', line.strip())
        if match:
            checked.add(match.group(1).strip())
    return checked


def matches_any(path: str, globs: list[str]) -> bool:
    return any(fnmatch(path, pattern) for pattern in globs)


changed_paths = [row['path'] for row in changed_rows]
tracked_paths = [path for path in changed_paths if matches_any(path, include_globs) and not matches_any(path, exclude_globs)]
if print_tracked_paths:
    if tracked_paths:
        print('\n'.join(tracked_paths))
    raise SystemExit(0)

existing_checked = parse_checked_items(blocks['verified']) | parse_checked_items(blocks['pending-device-tests'])
device_status = {label: (label in existing_checked) for _, label in DEVICE_CHECKS}
for device_id, label in DEVICE_CHECKS:
    if device_id in record_device_checks:
        device_status[label] = True

local_verification_stale = bool(tracked_paths) and not local_gate_verified
if local_gate_verified:
    local_gate_ok = True
else:
    existing_verified_block = blocks['verified']
    local_gate_ok = ('- [x] `bash scripts/verify-scripts.sh`' in existing_verified_block) and not local_verification_stale
    if local_gate_ok and not local_gate_verified_at:
        match = re.search(r'Last successful local gate: `([^`]+)`', existing_verified_block)
        if match:
            local_gate_verified_at = match.group(1)
if not local_gate_ok:
    local_gate_verified_at = 'not recorded' if not local_gate_verified_at else local_gate_verified_at

installer_text = Path('scripts/m1s-clean-install-umbrel.sh').read_text(encoding='utf-8')
status_lines: list[str] = []


def add_status(line: str) -> None:
    if line not in status_lines:
        status_lines.append(line)


tracked_path_set = set(tracked_paths)

if 'VERSION' in tracked_path_set:
    add_status(f'- `VERSION`: working version is now `{working_version}`.')
if 'CHANGELOG.md' in tracked_path_set:
    add_status(f'- `CHANGELOG.md`: release notes were updated for `{working_version}`.')
if 'scripts/m1s-clean-install-umbrel.sh' in tracked_path_set:
    add_status('- `scripts/m1s-clean-install-umbrel.sh`: installer flow changed in the current working tree.')
    if 'require_nvme_target_disk' in installer_text and 'Detected non-root NVMe SSD storage disks:' in installer_text:
        add_status('  - Enforces NVMe-only target selection and explicit non-NVMe refusal.')
    if 'assert_safe_root_target_layout' in installer_text and 'require_emmc_root_disk' in installer_text:
        add_status('  - Fails closed unless the ODROID M1S is clearly booted from eMMC and the install target is NVMe.')
    if 'stop_target_busy_processes' in installer_text:
        add_status('  - Cleans only target-scoped SSD holders and escalates from SIGTERM to SIGKILL when needed.')
    if 'Umbrel container failed to start' in installer_text:
        add_status('  - Treats Umbrel start failure as a hard installer failure before install-state recording.')
if 'scripts/m1s-update-umbrel.sh' in tracked_path_set:
    add_status(f'- `scripts/m1s-update-umbrel.sh`: updater version/migration path is aligned to `{working_version}`.')
if 'scripts/verify-scripts.sh' in tracked_path_set:
    add_status('- `scripts/verify-scripts.sh`: verifier expectations were updated for the current safety rules and release gates.')
if 'scripts/sync-dev-tracker.sh' in tracked_path_set:
    add_status('- `scripts/sync-dev-tracker.sh`: tracker sync automation now reads `.tracker-sync.json` and rewrites the auto-managed dev-tracker sections from repo state.')
if '.tracker-sync.json' in tracked_path_set:
    add_status('- `.tracker-sync.json`: tracker change detection now comes from include/exclude config instead of hardcoded path rules.')
if 'tests/test-installer-interactive.sh' in tracked_path_set:
    add_status('- `tests/test-installer-interactive.sh`: installer regression coverage now includes interactive aborts, root safety gating, and target-scoped busy cleanup.')
if 'tests/test-updater-migrations.sh' in tracked_path_set:
    add_status(f'- `tests/test-updater-migrations.sh`: updater migration expectations were refreshed for `{working_version}`.')
if 'tests/test-sync-dev-tracker.sh' in tracked_path_set:
    add_status('- `tests/test-sync-dev-tracker.sh`: tracker sync output is now covered by bootstrap, pending-check, and config-filter regression tests.')
if 'README.md' in tracked_path_set:
    add_status('- `README.md`: user-facing setup guidance changed in the current working tree.')

mapped_paths = {
    'VERSION',
    'CHANGELOG.md',
    'README.md',
    '.tracker-sync.json',
    'scripts/m1s-clean-install-umbrel.sh',
    'scripts/m1s-update-umbrel.sh',
    'scripts/verify-scripts.sh',
    'scripts/sync-dev-tracker.sh',
    'tests/test-installer-interactive.sh',
    'tests/test-updater-migrations.sh',
    'tests/test-sync-dev-tracker.sh',
}
for path in tracked_paths:
    if path not in mapped_paths:
        add_status(f'- `{path}`: tracked by `.tracker-sync.json` and modified in the current working tree.')

if not status_lines:
    status_lines = ['- No tracked project changes are currently detected outside excluded files.']

pending_labels = [label for _, label in DEVICE_CHECKS if not device_status[label]]
release_blockers: list[str] = []
if local_verification_stale:
    release_blockers.append('- Local verification is stale for the current tracked working tree; rerun `bash scripts/verify-scripts.sh`.')
if tracked_paths and pending_labels:
    release_blockers.append('- Pending checks are still open for the current tracked changes.')
if not release_status.startswith('released'):
    release_blockers.append(f'- `{working_version}` is not fully released yet (commit/tag/push/release still pending).')
if not release_blockers:
    release_blockers = ['- No automatic blockers are currently inferred from tracked repo state.']

next_actions: list[str] = []
if local_verification_stale:
    next_actions.append('1. Run `bash scripts/sync-dev-tracker.sh --run-local-gates` to refresh the local verification record.')
if tracked_paths and pending_labels:
    next_actions.append(f'{len(next_actions) + 1}. Finish the remaining checks listed under `Pending device tests`.')
if not release_status.startswith('released'):
    next_actions.append(f'{len(next_actions) + 1}. Review `git diff`, then commit/tag/release `{working_version}` once the blockers are closed.')
if not next_actions:
    next_actions = ['1. Keep the tracker synced after the next tracked state change.']

verified_lines = ['### Local']
verified_lines.append(f"- [{'x' if local_gate_ok else ' '}] `bash scripts/verify-scripts.sh`")
verified_lines.append(f'- Last successful local gate: `{local_gate_verified_at}`')
verified_lines.append('')
verified_lines.append('### Pending checks')
for _, label in DEVICE_CHECKS:
    verified_lines.append(f"- [{'x' if device_status[label] else ' '}] {label}")

pending_lines = [f'- [ ] {label}' for label in pending_labels]
if not pending_lines:
    pending_lines = ['- [x] No remaining checks are inferred for the current state.']

replacement_blocks = {
    'last-updated': f'_Last updated: {now_kst}_',
    'current-branch': '\n'.join([
        f'- Branch: `{branch_name}`',
        f'- Working version: `{working_version}`',
        f'- Release status: `{release_status}`',
    ]),
    'current-status': '\n'.join(status_lines),
    'verified': '\n'.join(verified_lines),
    'pending-device-tests': '\n'.join(pending_lines),
    'release-blockers': '\n'.join(release_blockers),
    'next-actions': '\n'.join(next_actions),
}

for marker, body in replacement_blocks.items():
    pattern = re.compile(rf'(<!-- AUTO:BEGIN {re.escape(marker)} -->)\n?.*?(<!-- AUTO:END {re.escape(marker)} -->)', re.S)
    text = pattern.sub(lambda match: f"{match.group(1)}\n{body}\n{match.group(2)}", text)

if record_operational_events:
    history_header = '## Historical notes'
    if history_header not in text:
        raise SystemExit('dev tracker must preserve a manual historical notes section')
    date_heading = f"### {datetime.now().astimezone().strftime('%Y-%m-%d')} Session summary"
    event_lines = [f"- [{item['category']}] {item['message']}" for item in record_operational_events]
    heading_pattern = re.compile(rf'^{re.escape(date_heading)}$', re.M)
    heading_match = heading_pattern.search(text)
    if heading_match:
        section_start = heading_match.end()
        next_heading = re.search(r'(?m)^### ', text[section_start:])
        section_end = section_start + (next_heading.start() if next_heading else len(text[section_start:]))
        existing_section = text[section_start:section_end]
        new_lines = [line for line in event_lines if line not in existing_section]
        if new_lines:
            insertion = ('\n' if not existing_section.startswith('\n') else '') + '\n'.join(new_lines) + '\n'
            text = text[:section_end] + insertion + text[section_end:]
    else:
        insertion_point = text.find(history_header) + len(history_header)
        new_block = f"\n\n{date_heading}\n" + '\n'.join(event_lines) + '\n'
        text = text[:insertion_point] + new_block + text[insertion_point:]

tracker_path.write_text(text, encoding='utf-8')
print(f'Updated {tracker_path}')
PY
