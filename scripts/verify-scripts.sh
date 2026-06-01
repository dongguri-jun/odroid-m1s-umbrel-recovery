#!/usr/bin/env bash
set -Eeuo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

scripts=(scripts/*.sh)
test_scripts=(tests/*.sh)
git_hooks=(.githooks/*)
installer="scripts/m1s-clean-install-umbrel.sh"
updater="scripts/m1s-update-umbrel.sh"
chainstate_starter="scripts/m1s-start-bitcoin-chainstate-rebuild.sh"
reindex_starter="scripts/m1s-start-bitcoin-reindex.sh"
full_resync_starter="scripts/m1s-start-bitcoin-full-resync.sh"
chainstate_requester="scripts/m1s-request-bitcoin-chainstate-rebuild.sh"
recovery_checker="scripts/m1s-check-bitcoin-recovery-status.sh"
chainstate_checker="scripts/m1s-check-bitcoin-chainstate-rebuild.sh"
initial_setup="scripts/m1s-initial-setup.sh"
system_updater="scripts/m1s-update-system-packages.sh"

printf '[verify] bash syntax\n'
for script in "${scripts[@]}" "${test_scripts[@]}" "${git_hooks[@]}"; do
  bash -n "$script"
  printf '  ok %s\n' "$script"
done

printf '[verify] shellcheck\n'
if command -v shellcheck >/dev/null 2>&1; then
  shellcheck -x "${scripts[@]}" "${test_scripts[@]}" "${git_hooks[@]}"
  printf '  ok shellcheck %s %s %s\n' "${scripts[*]}" "${test_scripts[*]}" "${git_hooks[*]}"
else
  printf '  skip shellcheck not installed\n'
fi

printf '[verify] script version flags\n'
for script in "$installer" "$updater" "$initial_setup" "$system_updater" "$chainstate_starter" "$reindex_starter" "$full_resync_starter" "$chainstate_requester" "$recovery_checker" "$chainstate_checker"; do
  bash "$script" --version >/dev/null
  printf '  ok bash %s --version\n' "$script"
done

printf '[verify] version consistency\n'
python3 - <<'PY'
from pathlib import Path
import re

version = Path('VERSION').read_text(encoding='utf-8').strip()
for path in [
    Path('scripts/m1s-clean-install-umbrel.sh'),
    Path('scripts/m1s-update-umbrel.sh'),
    Path('scripts/m1s-initial-setup.sh'),
    Path('scripts/m1s-update-system-packages.sh'),
    Path('scripts/m1s-start-bitcoin-chainstate-rebuild.sh'),
    Path('scripts/m1s-start-bitcoin-reindex.sh'),
    Path('scripts/m1s-start-bitcoin-full-resync.sh'),
    Path('scripts/m1s-request-bitcoin-chainstate-rebuild.sh'),
    Path('scripts/m1s-check-bitcoin-recovery-status.sh'),
    Path('scripts/m1s-check-bitcoin-chainstate-rebuild.sh'),
]:
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
    'require_nvme_target_disk',
    'detect_root_disk',
    'require_emmc_root_disk',
    'assert_safe_root_target_layout',
    'refusing to format any NVMe target until the root disk is identified',
    'expects ODROID M1S to boot from eMMC',
    'Detected non-root NVMe SSD storage disks:',
    'No candidate NVMe SSD storage disks were found.',
    'collect_target_busy_pids',
    'filter_killable_target_pids',
    'stop_target_busy_processes',
    'kill -TERM',
    'kill -KILL',
    'The selected NVMe SSD is still being used by old processes.',
    'automatic SSD process cleanup',
    'Umbrel container failed to start',
    'install cannot be marked successful until Umbrel is running',
    'sudo docker logs umbrel',
    'Install health summary',
    'HTTP by device IP',
    'HTTP by umbrel.local',
    'install_fstrim_dropin',
    'fstrim.service.d',
    'm1s-no-syscallfilter.conf',
    'SystemCallFilter=',
    'SystemCallErrorNumber=',
    'disable_ufw_for_umbrel',
    'ufw --force disable',
    'reset-failed fstrim.service',
    'start fstrim.service',
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
    ('safe root-target layout gate must appear before mkfs', 'assert_safe_root_target_layout', 'run_cmd mkfs.ext4 -F "$TARGET_PARTITION"'),
    ('destructive confirmation must appear before service cleanup', 'Type ERASE-EMMC-AND-FORMAT-SSD-AND-INSTALL-UMBREL to continue', 'Stopping and removing Incus containers if present'),
    ('target-scoped busy process cleanup must happen before mkfs', 'stop_target_busy_processes', 'run_cmd mkfs.ext4 -F "$TARGET_PARTITION"'),
    ('SIGTERM must be attempted before SIGKILL', 'kill -TERM', 'kill -KILL'),
    ('mount verification must happen before Docker install', 'Mount verification failed', 'Installing fresh Docker'),
    ('Docker mount guard must be installed before Umbrel start', 'Installing self-heal guard for fullnode mount', 'Pulling and starting Umbrel'),
    ('Umbrel start failure must fail before install state recording', 'Umbrel container failed to start', 'Recording install state'),
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
    '--skip-sync',
    'AUTO_SYNC=1',
    'OFFICIAL_REPO_SLUG="dongguri-jun/odroid-m1s-umbrel-recovery"',
    'origin_url_is_official',
    'sync_repository_to_origin_main',
    'safe_directory="safe.directory=$repo_root"',
    'git -c "$safe_directory" -C "$repo_root" fetch origin',
    'git -c "$safe_directory" -C "$repo_root" reset --hard origin/main',
    'exec bash "$updated_script" --skip-sync "$@"',
    'CURRENT_VERSION',
    'TARGET_VERSION',
    'DATA_DIR="/mnt/fullnode"',
    'UMBREL_IMAGE="dockurr/umbrel:1.7.3@sha256:',
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
    '"0.4.12_to_0.4.13"',
    '"0.4.13_to_0.4.14"',
    '"0.4.14_to_0.4.15"',
    '"0.4.15_to_0.4.16"',
    '"0.4.16_to_0.4.17"',
    '"0.4.17_to_0.4.18"',
    '"0.4.18_to_0.5.0"',
    '"0.5.0_to_0.5.1"',
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
    'STOPPED_APP_CONTAINERS=()',
    'APP_CONTAINERS_STOPPED=0',
    'load_running_app_containers',
    'print_running_app_container_hint',
    'stop_running_app_containers',
    'start_stopped_app_containers',
    'docker stop --timeout "$APP_STOP_TIMEOUT_SECONDS"',
    'docker stop umbrel',
    'docker rm umbrel',
    'HOST_DATA_ALIAS="/data"',
    'DATA_ALIAS_FSTAB_OPTIONS="bind,nofail,x-systemd.requires-mounts-for=$DATA_DIR"',
    'ensure_host_data_alias',
    'host_data_alias_ready',
    'umbrel_container_data_source',
    'docker run -d --name umbrel --restart always -p 80:80 -v "$data_source:/data" -v /var/run/docker.sock:/var/run/docker.sock --stop-timeout 60 --pid=host --privileged',
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
    'install_fstrim_dropin',
    'fstrim.service.d',
    'm1s-no-syscallfilter.conf',
    'SystemCallFilter=',
    'SystemCallErrorNumber=',
    'reset-failed fstrim.service',
    'start fstrim.service',
    'precheck_0_4_18_to_0_5_0',
    'apply_0_4_18_to_0_5_0',
    'postcheck_0_4_18_to_0_5_0',
    'disable_ufw_for_umbrel',
    'ufw --force disable',
    'precheck_0_5_0_to_0_5_1',
    'apply_0_5_0_to_0_5_1',
    'postcheck_0_5_0_to_0_5_1',
    'precheck_0_5_1_to_0_5_2',
    'apply_0_5_1_to_0_5_2',
    'postcheck_0_5_1_to_0_5_2',
    '"0.5.2_to_0.5.3"',
    '"0.5.3_to_0.5.4"',
    '"0.5.4_to_0.5.5"',
    '"0.5.5_to_0.5.6"',
    '"0.5.6_to_0.5.7"',
    'remove_pwm_fan_config',
    'precheck_0_5_2_to_0_5_3',
    'apply_0_5_2_to_0_5_3',
    'postcheck_0_5_2_to_0_5_3',
    'precheck_0_5_3_to_0_5_4',
    'apply_0_5_3_to_0_5_4',
    'postcheck_0_5_3_to_0_5_4',
    'precheck_0_5_4_to_0_5_5',
    'apply_0_5_4_to_0_5_5',
    'postcheck_0_5_4_to_0_5_5',
    'precheck_0_5_5_to_0_5_6',
    'apply_0_5_5_to_0_5_6',
    'postcheck_0_5_5_to_0_5_6',
    'precheck_0_5_6_to_0_5_7',
    'apply_0_5_6_to_0_5_7',
    'postcheck_0_5_6_to_0_5_7',
    'precheck_0_5_7_to_0_5_8',
    'apply_0_5_7_to_0_5_8',
    'postcheck_0_5_7_to_0_5_8',
    'precheck_0_5_8_to_0_5_9',
    'apply_0_5_8_to_0_5_9',
    'postcheck_0_5_8_to_0_5_9',
    'precheck_0_5_9_to_0_5_10',
    'apply_0_5_9_to_0_5_10',
    'postcheck_0_5_9_to_0_5_10',
    'precheck_0_5_10_to_0_5_11',
    'apply_0_5_10_to_0_5_11',
    'postcheck_0_5_10_to_0_5_11',
    'precheck_0_5_11_to_0_5_12',
    'apply_0_5_11_to_0_5_12',
    'postcheck_0_5_11_to_0_5_12',
    'precheck_0_5_12_to_0_5_13',
    'apply_0_5_12_to_0_5_13',
    'postcheck_0_5_12_to_0_5_13',
    'precheck_0_5_15_to_0_5_16',
    'apply_0_5_15_to_0_5_16',
    'postcheck_0_5_15_to_0_5_16',
    'precheck_0_5_16_to_0_5_17',
    'apply_0_5_16_to_0_5_17',
    'postcheck_0_5_16_to_0_5_17',
    'precheck_0_5_17_to_0_5_18',
    'apply_0_5_17_to_0_5_18',
    'postcheck_0_5_17_to_0_5_18',
    '/boot/config.ini',
    '[overlay_pwm]',
    'overlay_profile',
    'pwm1',
    'pwm2',
    '0.5.7_to_0.5.8',
    '0.5.8_to_0.5.9',
    '0.5.9_to_0.5.10',
    '0.5.10_to_0.5.11',
    '0.5.11_to_0.5.12',
    '0.5.12_to_0.5.13',
    '0.5.13_to_0.5.14',
    '0.5.14_to_0.5.15',
    '0.5.15_to_0.5.16',
    '0.5.16_to_0.5.17',
    '0.5.17_to_0.5.18',
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
if pos('load_running_app_containers', refresh) > pos('stop_running_app_containers', refresh):
    raise SystemExit('Updater must capture running app containers before attempting to stop them')
if pos('stop_running_app_containers', refresh) > pos('docker stop umbrel', refresh):
    raise SystemExit('Umbrel app containers must stop before the top-level umbrel container is stopped')
for mutator in ['docker stop umbrel', 'docker rm umbrel', 'run_umbrel_container "$UMBREL_IMAGE"']:
    if pos('assert_fullnode_data_mount_safe', refresh) > pos(mutator, refresh):
        raise SystemExit(f'Umbrel data mount safety check must happen before {mutator}')
if pos('if [[ "$DRY_RUN" -eq 1 ]]', refresh) > pos('docker pull "$UMBREL_IMAGE"', refresh):
    raise SystemExit('Dry-run branch must return before docker pull mutates image cache')
if pos('start_stopped_app_containers', refresh) < pos('wait_for_umbrel_container', refresh):
    raise SystemExit('Previously running app containers must only restart after the new umbrel container is running')
print('  ok updater preserves data-mount gates, check/dry-run path, and canonical Umbrel refresh flags')
PY


printf '[verify] system package updater safety invariants\n'
python3 - <<'PY'
from pathlib import Path
text = Path('scripts/m1s-update-system-packages.sh').read_text(encoding='utf-8')
for forbidden in ['mkfs.', 'sfdisk', 'parted', 'wipefs', 'sgdisk', 'gdisk', 'blkdiscard', 'shred']:
    if forbidden in text:
        raise SystemExit(f'System package updater must never contain destructive disk command: {forbidden}')
required = [
    'SCRIPT_VERSION="0.5.18"',
    '--dry-run',
    '--no-reboot',
    'STOP_TIMEOUT_SECONDS=300',
    'APT_LOCK_TIMEOUT_SECONDS=300',
    'apt_update_command',
    'docker ps --format',
    'Bitcoin-related containers are running and will be stopped gracefully',
    'docker stop --timeout "$STOP_TIMEOUT_SECONDS"',
    'run_noninteractive',
    'apt_upgrade_command',
    'dpkg_configure_command',
    '--force-confdef',
    '--force-confold',
    'apt_fix_install_command',
    'apt_check_command',
    'apt_clean_command',
    'clean_apt_cache',
    'DPkg::Lock::Timeout="$APT_LOCK_TIMEOUT_SECONDS"',
    '/var/run/reboot-required',
    'run_cmd systemctl reboot',
    'docker container inspect "$container"',
    'docker start "$container"',
]
missing = [needle for needle in required if needle not in text]
if missing:
    print('Missing expected system package updater invariant text:')
    for needle in missing:
        print(f'  {needle}')
    raise SystemExit(1)

def pos(needle: str, haystack: str = text) -> int:
    idx = haystack.find(needle)
    if idx == -1:
        raise SystemExit(f'Missing text for order invariant: {needle}')
    return idx

main = text[pos('main()'):]
if pos('apt_update_command', main) > pos('if command -v docker', main):
    raise SystemExit('apt package lists should update before Docker/container handling')
if pos('stop_running_containers', main) > pos('apt_upgrade_command', main):
    raise SystemExit('containers must stop before apt upgrade runs')
if pos('apt_upgrade_command', main) > pos('dpkg_configure_command', main):
    raise SystemExit('apt upgrade must run before dpkg repair/check phase')
if pos('dpkg_configure_command', main) > pos('apt_fix_install_command', main):
    raise SystemExit('dpkg configure repair must run before apt fix install')
if pos('apt_fix_install_command', main) > pos('apt_check_command', main):
    raise SystemExit('apt fix install must run before apt check')
if pos('apt_check_command', main) > pos('clean_apt_cache', main):
    raise SystemExit('apt cache clean must run only after apt check succeeds')
if pos('clean_apt_cache', main) > pos('print_reboot_required_status', main):
    raise SystemExit('apt cache clean should run before reboot-required status is reported')
if pos('print_reboot_required_status', main) > pos('if reboot_required; then', main):
    raise SystemExit('reboot status should print before reboot decision')
if pos('if reboot_required; then', main) > pos('run_cmd systemctl reboot', main):
    raise SystemExit('systemctl reboot must stay behind reboot-required gate')
if pos('if reboot_required; then', main) > pos('start_stopped_containers', main):
    raise SystemExit('container restart must happen only after reboot-required handling')
print('  ok system package updater stops containers before apt upgrade and reboots only behind reboot-required gate')
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

printf '[verify] public-clean publish guard\n'
python3 - <<'PY'
from pathlib import Path
import subprocess

files = {
    '.githooks/pre-push': [
        'refs/heads/public-clean',
        'Blocked: refusing to create or update remote public-clean.',
        'git push origin public-clean:main',
        'git push -u origin public-clean',
        'git push origin HEAD:public-clean',
    ],
    'scripts/install-public-clean-guard.sh': [
        'git rev-parse --is-inside-work-tree',
        'git config --local core.hooksPath .githooks',
        'git branch --unset-upstream public-clean',
        'allowed publish command: git push origin public-clean:main',
    ],
    'scripts/publish-public.sh': [
        'Publish must run from public-clean.',
        'Local public-clean must not track an upstream.',
        'git ls-remote --exit-code --heads origin public-clean',
        'git push origin public-clean:main',
    ],
}
for path, needles in files.items():
    file_path = Path(path)
    if not file_path.exists():
        raise SystemExit(f'{path} is missing')
    text = file_path.read_text(encoding='utf-8')
    missing = [needle for needle in needles if needle not in text]
    if missing:
        print(f'{path} is missing expected public-clean guard text:')
        for needle in missing:
            print(f'  {needle}')
        raise SystemExit(1)

zero = '0' * 40
one = '1' * 40
cases = [
    ('public-clean branch push', f'refs/heads/public-clean {one} refs/heads/public-clean {zero}\n', False),
    ('HEAD to public-clean push', f'HEAD {one} refs/heads/public-clean {zero}\n', False),
    ('public-clean to main publish', f'refs/heads/public-clean {one} refs/heads/main {zero}\n', True),
]
for label, stdin, should_pass in cases:
    result = subprocess.run(
        ['.githooks/pre-push', 'origin', 'https://github.com/dongguri-jun/odroid-m1s-umbrel-recovery.git'],
        input=stdin,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )
    passed = result.returncode == 0
    if passed != should_pass:
        print(f'pre-push behavior failed for {label}')
        print(f'  expected pass: {should_pass}')
        print(f'  exit code: {result.returncode}')
        print(f'  stderr: {result.stderr}')
        raise SystemExit(1)
print('  ok public-clean remote branch recreation is blocked by hook, installer, and publish script')
PY

printf '[verify] complete\n'
