#!/usr/bin/env bash
set -Eeuo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

scripts=(scripts/*.sh)
test_scripts=(tests/*.sh)
installer="scripts/m1s-clean-install-umbrel.sh"
updater="scripts/m1s-update-umbrel.sh"

printf '[verify] bash syntax\n'
for script in "${scripts[@]}" "${test_scripts[@]}"; do
  bash -n "$script"
  printf '  ok %s\n' "$script"
done

printf '[verify] shellcheck\n'
if command -v shellcheck >/dev/null 2>&1; then
  shellcheck -x "${scripts[@]}" "${test_scripts[@]}"
  printf '  ok shellcheck %s %s\n' "${scripts[*]}" "${test_scripts[*]}"
else
  printf '  skip shellcheck not installed\n'
fi

printf '[verify] script version flags\n'
for script in "$installer" "$updater"; do
  bash "$script" --version >/dev/null
  printf '  ok bash %s --version\n' "$script"
done

printf '[verify] version consistency\n'
python3 - <<'PY'
from pathlib import Path
import re

version = Path('VERSION').read_text(encoding='utf-8').strip()
for path in [Path('scripts/m1s-clean-install-umbrel.sh'), Path('scripts/m1s-update-umbrel.sh')]:
    text = path.read_text(encoding='utf-8')
    match = re.search(r'^SCRIPT_VERSION="([^"]+)"', text, flags=re.M)
    if not match:
        raise SystemExit(f'{path}: SCRIPT_VERSION is missing')
    if match.group(1) != version:
        raise SystemExit(f'{path}: SCRIPT_VERSION {match.group(1)} does not match VERSION {version}')
print(f'  ok VERSION and script versions match ({version})')
PY

printf '[verify] unsafe heredoc wrappers\n'
python3 - <<'PY'
from pathlib import Path
import re
import sys

# This catches the class of bug where a multi-line heredoc is embedded inside a
# double-quoted shell string, for example:
#   wrapper "... python3 - <<'PY'
#   ... Python code containing " characters ...
#   PY"
# Bash parses the outer double-quoted string before Python ever runs, so a valid
# looking dry-run can still break during real execution.
patterns = [
    re.compile(r'run_shell\s+"[^"\n]*<<[\'\"]?[A-Z_]+', re.DOTALL),
    re.compile(r'bash\s+-lc\s+"[^"\n]*<<[\'\"]?[A-Z_]+', re.DOTALL),
]
violations = []
for path in sorted(Path('scripts').glob('*.sh')):
    text = path.read_text(encoding='utf-8')
    for pattern in patterns:
        for match in pattern.finditer(text):
            line_no = text.count('\n', 0, match.start()) + 1
            excerpt = text[match.start():match.start() + 100].splitlines()[0]
            violations.append(f'{path}:{line_no}: {excerpt}')

if violations:
    print('Unsafe heredoc wrapper found. Use direct heredoc execution or a standalone helper file instead.')
    for item in violations:
        print(f'  {item}')
    sys.exit(1)

print('  ok no heredoc embedded in double-quoted shell command wrappers')
PY

printf '[verify] installer safety invariants\n'
python3 - <<'PY'
from pathlib import Path

text = Path('scripts/m1s-clean-install-umbrel.sh').read_text(encoding='utf-8')
required = [
    'set -Eeuo pipefail',
    'Type ERASE-EMMC-AND-FORMAT-SSD-AND-INSTALL-UMBREL to continue',
    'Refusing to format the root/system disk',
    'TARGET_DISK" == "$ROOT_DISK',
    'run_cmd mkfs.ext4 -F "$TARGET_PARTITION"',
    'Mount verification failed',
    'expected $TARGET_PARTITION mounted at $DATA_DIR',
    'RequiresMountsFor=$DATA_DIR',
    'docker run -d --name umbrel',
    'install_umbrel_safe_shutdown',
    'm1s-umbrel-autostart.service',
    'docker update --restart=always umbrel',
    'docker start umbrel',
    'docker exec -i umbrel python3',
    'docker update --restart=no',
    'sleep 45; docker stop --time 15 "$(hostname)"',
    'Install health summary',
    'HTTP by device IP',
    'HTTP by umbrel.local',
]
missing = [needle for needle in required if needle not in text]
if missing:
    print('Missing expected installer safety/health invariant text:')
    for needle in missing:
        print(f'  {needle}')
    raise SystemExit(1)

def pos(needle: str) -> int:
    idx = text.find(needle)
    if idx == -1:
        raise AssertionError(needle)
    return idx

order_checks = [
    ('root disk guard must appear before mkfs', 'Refusing to format the root/system disk', 'run_cmd mkfs.ext4 -F "$TARGET_PARTITION"'),
    ('destructive confirmation must appear before service cleanup', 'Type ERASE-EMMC-AND-FORMAT-SSD-AND-INSTALL-UMBREL to continue', 'Stopping and removing Incus containers if present'),
    ('mount verification must happen before Docker install', 'Mount verification failed', 'Installing fresh Docker'),
    ('Docker mount guard must be installed before Umbrel start', 'Installing self-heal guard for fullnode mount', 'Pulling and starting Umbrel'),
    ('health summary must run before install state recording', 'Install health summary', 'Recording install state'),
]
for label, before, after in order_checks:
    if pos(before) > pos(after):
        raise SystemExit(f'Order invariant failed: {label}')
print('  ok installer safety invariants and critical ordering')
PY

printf '[verify] updater safety invariants\n'
python3 - <<'PY'
from pathlib import Path
text = Path('scripts/m1s-update-umbrel.sh').read_text(encoding='utf-8')
for forbidden in ['mkfs.', 'sfdisk', 'parted', 'wipefs', 'sgdisk', 'gdisk', 'blkdiscard', 'shred']:
    if forbidden in text:
        raise SystemExit(f'Updater must never contain destructive disk command: {forbidden}')
required = [
    'without touching user data',
    '--check',
    '--dry-run',
    'CURRENT_VERSION',
    'TARGET_VERSION',
    'DATA_DIR="/mnt/fullnode"',
    'UMBREL_IMAGE="dockurr/umbrel:1.5.0@sha256:',
    'MIGRATIONS=(',
    '"0.1.0_to_0.2.0"',
    '"0.4.4_to_0.4.5"',
    '"0.4.5_to_0.4.6"',
    '"0.4.6_to_0.4.7"',
    '"0.4.7_to_0.4.8"',
    '"0.4.8_to_0.4.9"',
    '"0.4.9_to_0.4.10"',
    '"0.4.10_to_0.4.11"',
    '"0.4.11_to_0.4.12"',
    'applied_steps',
    'in_progress_step',
    'failed_step',
    'last_error',
    'last_completed_version',
    'run_migration_step',
    'mark_step_started',
    'mark_step_completed',
    'mark_step_failed',
    'finalize_install_state',
    'assert_fullnode_data_mount_safe',
    'findmnt --target "$DATA_DIR"',
    'inspect_umbrel_mount_source /data',
    'inspect_umbrel_mount_source /var/run/docker.sock',
    'docker pull "$UMBREL_IMAGE"',
    'docker stop umbrel',
    'docker rm umbrel',
    'docker run -d --name umbrel --restart always -p 80:80 -v "$DATA_DIR:/data" -v /var/run/docker.sock:/var/run/docker.sock --stop-timeout 60 --pid=host --privileged',
    'SAFE_SHUTDOWN_SERVICE="/etc/systemd/system/m1s-umbrel-autostart.service"',
    'install_umbrel_safe_shutdown',
    'postcheck_umbrel_safe_shutdown',
    'docker update --restart=always umbrel',
    'docker start umbrel',
    'docker exec -i umbrel python3',
    'docker update --restart=no',
    'sleep 45; docker stop --time 15 "$(hostname)"',
    'precheck_0_4_7_to_0_4_8',
    'apply_0_4_7_to_0_4_8',
    'postcheck_0_4_7_to_0_4_8',
    'precheck_0_4_8_to_0_4_9',
    'apply_0_4_8_to_0_4_9',
    'postcheck_0_4_8_to_0_4_9',
    'precheck_0_4_9_to_0_4_10',
    'apply_0_4_9_to_0_4_10',
    'postcheck_0_4_9_to_0_4_10',
    'restore_umbrel_shutdown_ui',
    'verify_umbrel_shutdown_ui_restored',
    'precheck_0_4_10_to_0_4_11',
    'apply_0_4_10_to_0_4_11',
    'postcheck_0_4_10_to_0_4_11',
    'precheck_0_4_11_to_0_4_12',
    'apply_0_4_11_to_0_4_12',
    'postcheck_0_4_11_to_0_4_12',
]
missing = [needle for needle in required if needle not in text]
if missing:
    print('Missing expected updater invariant text:')
    for needle in missing:
        print(f'  {needle}')
    raise SystemExit(1)

def pos(needle: str, haystack: str = text) -> int:
    idx = haystack.find(needle)
    if idx == -1:
        raise SystemExit(f'Missing text for order invariant: {needle}')
    return idx

main = text[pos('TARGET_VERSION="$SCRIPT_VERSION"'):]
if pos('if [[ "$CHECK_ONLY" -eq 1 ]]', main) > pos('global_preflight', main):
    raise SystemExit('--check must exit before preflight can touch runtime state')
if pos('if [[ "$CHECK_ONLY" -eq 1 ]]', main) > pos('if ! run_migration_step "$step"', main):
    raise SystemExit('--check must exit before migration handlers can run')
if pos('if [[ "$CHECK_ONLY" -eq 1 ]]', main) > pos('finalize_install_state "$TARGET_VERSION"', main):
    raise SystemExit('--check must exit before final install state can be written')
if pos('mark_step_started "$step"') > pos('if ! "$apply_fn"'):
    raise SystemExit('migration step must be marked in-progress before apply')
if pos('if ! "$apply_fn"') > pos('mark_step_failed "$step" "apply failed"'):
    raise SystemExit('apply failure must be recorded before returning from step')
if pos('if ! "$postcheck_fn"') > pos('mark_step_failed "$step" "postcheck failed"'):
    raise SystemExit('postcheck failure must be recorded before returning from step')
completed_block = text[pos('elif action == "completed":'):pos('elif action == "failed":')]
if 'base["version"] = version' in completed_block or 'base["host_version"] = version' in completed_block:
    raise SystemExit('completed migration steps must not write final version fields before finalize')
if pos('run_migration_step "$step"', main) > pos('finalize_install_state "$TARGET_VERSION"', main):
    raise SystemExit('final version must only be recorded after migration loop')

safe = text[pos('patch_umbrel_shutdown_source()'):pos('refresh_umbrel_system_container()')]
if pos('docker update --restart=no', safe) > pos('sleep 45; docker stop --time 15 "$(hostname)"', safe):
    raise SystemExit('Umbrel shutdown patch must disable Docker restart before scheduling delayed top-level container stop')
if pos('docker update --restart=always umbrel', safe) > pos('docker start umbrel', safe):
    raise SystemExit('Boot restore service must restore restart policy before starting Umbrel')
if pos('systemctl enable m1s-umbrel-autostart.service', safe) > pos('docker restart --time 60 umbrel', safe):
    raise SystemExit('Boot restore service must be enabled before Umbrel is restarted into patched code')

refresh = text[pos('refresh_umbrel_system_container()'):]
if pos('assert_fullnode_data_mount_safe', refresh) > pos('docker pull "$UMBREL_IMAGE"', refresh):
    raise SystemExit('Umbrel data mount safety check must happen before docker pull')
for mutator in ['docker stop umbrel', 'docker rm umbrel', 'run_umbrel_container "$UMBREL_IMAGE"']:
    if pos('assert_fullnode_data_mount_safe', refresh) > pos(mutator, refresh):
        raise SystemExit(f'Umbrel data mount safety check must happen before {mutator}')
if pos('if [[ "$DRY_RUN" -eq 1 ]]', refresh) > pos('docker pull "$UMBREL_IMAGE"', refresh):
    raise SystemExit('Dry-run branch must return before docker pull mutates image cache')
print('  ok updater preserves data-mount gates, check/dry-run path, and canonical Umbrel refresh flags')
PY

printf '[verify] updater unit tests\n'
for test_script in "${test_scripts[@]}"; do
  bash "$test_script"
  printf '  ok %s\n' "$test_script"
done

printf '[verify] workflow presence\n'
python3 - <<'PY'
from pathlib import Path
workflow = Path('.github/workflows/verify.yml')
if not workflow.exists():
    raise SystemExit('.github/workflows/verify.yml is missing')
text = workflow.read_text(encoding='utf-8')
required = [
    'actions/checkout@v5',
    'shellcheck',
    'bash scripts/verify-scripts.sh',
    'pull_request:',
    'push:',
]
missing = [needle for needle in required if needle not in text]
if missing:
    print('Workflow is missing expected checks:')
    for needle in missing:
        print(f'  {needle}')
    raise SystemExit(1)
print('  ok GitHub workflow runs the verifier with shellcheck available')
PY

printf '[verify] release gate\n'
python3 - <<'PY'
from pathlib import Path
release = Path('scripts/release.sh')
if not release.exists():
    raise SystemExit('scripts/release.sh is missing')
text = release.read_text(encoding='utf-8')
required = [
    'gh run list --workflow "$workflow_name" --branch main --commit "$head_sha"',
    "run.get('status') != 'completed' or run.get('conclusion') != 'success'",
    'Local HEAD must match origin/main before releasing.',
    'Remote tag already exists',
    'GitHub Release already exists',
    'CHANGELOG.md is missing section',
]
missing = [needle for needle in required if needle not in text]
if missing:
    print('Release gate is missing expected safety checks:')
    for needle in missing:
        print(f'  {needle}')
    raise SystemExit(1)
print('  ok release script gates tags/releases on clean tree, pushed HEAD, changelog, and successful CI')
PY

printf '[verify] complete\n'
