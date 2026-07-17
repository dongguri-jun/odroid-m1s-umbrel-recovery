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
expected_version = '0.5.25'
if not re.fullmatch(r'\d+\.\d+\.\d+', version):
    raise SystemExit(f'VERSION must be plain semver MAJOR.MINOR.PATCH, got {version!r}')
if version != expected_version:
    raise SystemExit(f'VERSION {version} does not match expected release {expected_version}')

covered = [
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
]
detected = sorted(
    path for path in Path('scripts').glob('*.sh')
    if re.search(r'^SCRIPT_VERSION="[^"]+"', path.read_text(encoding='utf-8'), flags=re.M)
)
if detected != sorted(covered):
    raise SystemExit(
        'Version consistency coverage mismatch: detected SCRIPT_VERSION files are ' +
        ', '.join(str(path) for path in detected)
    )

for path in covered:
    text = path.read_text(encoding='utf-8')
    match = re.search(r'^SCRIPT_VERSION="([^"]+)"', text, flags=re.M)
    if not match:
        raise SystemExit(f'{path}: SCRIPT_VERSION is missing')
    if match.group(1) != expected_version:
        raise SystemExit(f'{path}: SCRIPT_VERSION {match.group(1)} does not match expected {expected_version}')
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
    'IMAGE="dockurr/umbrel:1.7.4@sha256:e00c07a838ce3b50641a0a984abe155a7223abacab3426a55409edf21b6e0124"',
    '--image IMAGE',
    '    --image)',
    'RESOLVED_UMBREL_IMAGE_ID=""',
    'RESOLVED_UMBREL_IMAGE_ARCHITECTURE=""',
    'EXPECTED_TOR_PROXY_IMAGE="ghcr.io/getumbrel/tor:0.4.9.11"',
    'install_docker_engine_from_official_apt_repo',
    'https://download.docker.com/linux/ubuntu/gpg',
    'docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin',
    'Mount verification failed',
    'expected $TARGET_PARTITION mounted at $DATA_DIR',
    'RequiresMountsFor=$DATA_DIR',
    'docker run -d --name umbrel',
    'pull_and_verify_umbrel_image',
    'verify_pulled_umbrel_image',
    "docker image inspect --format='{{.Id}}' \"$IMAGE\"",
    "docker image inspect --format='{{.Architecture}}' \"$IMAGE\"",
    'Pulled Umbrel image architecture is',
    'RESOLVED_UMBREL_IMAGE_ID="$image_id"',
    'RESOLVED_UMBREL_IMAGE_ARCHITECTURE="$image_architecture"',
    'umbrel_runtime_health_once',
    'wait_for_umbrel_runtime_health',
    'record_install_state',
    "docker inspect --format='{{.Config.Image}}' umbrel",
    "docker inspect --format='{{.Image}}' umbrel",
    '"$image_ref" != "$IMAGE"',
    '"$image_id" != "$RESOLVED_UMBREL_IMAGE_ID"',
    '"image_id": image_id',
    'HostConfig.RestartPolicy.Name',
    'eq .Destination "/data"',
    'eq .Destination "/var/run/docker.sock"',
    'CANONICAL_AUTH_CONTAINER="umbrel_auth"',
    'CANONICAL_TOR_PROXY_CONTAINER="umbrel_tor_proxy"',
    'docker inspect --format=\'{{.State.Status}}\' "$CANONICAL_AUTH_CONTAINER"',
    'docker inspect --format=\'{{.State.Status}}\' "$CANONICAL_TOR_PROXY_CONTAINER"',
    'docker inspect --format=\'{{.Config.Image}}\' "$CANONICAL_TOR_PROXY_CONTAINER"',
    'is_expected_tor_proxy_image',
    '@sha256:[0-9a-f]{64}',
    'curl -fsS --max-time 10 http://127.0.0.1',
    'install_umbrel_safe_shutdown',
    'm1s-umbrel-autostart.service',
    'docker update --restart=always umbrel',
    'docker start umbrel',
    'docker exec -i umbrel python3',
    'docker update --restart=no',
    'sleep 45; docker stop --time 15 "$(hostname)"',
    'patch_umbrel_shutdown_ui',
    'verify_umbrel_shutdown_ui',
    'ce.isError||ce.failureCount>0',
    'he==="shutting-down"&&!v&&(b(!0),setTimeout(()=>S(!0),30*Kh))',
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

if 'dockurr/umbrel:1.7.3' in text:
    raise SystemExit('Installer must not retain the old Dockur Umbrel 1.7.3 product pin')

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

install_phase = text[text.find('info "Pulling and starting Umbrel"'):]
def install_pos(needle: str) -> int:
    idx = install_phase.find(needle)
    if idx == -1:
        raise SystemExit(f'Missing installer runtime sequence text: {needle}')
    return idx

if install_pos('pull_and_verify_umbrel_image') > install_pos('run_cmd docker run -d --name umbrel'):
    raise SystemExit('Order invariant failed: pulled image verification must happen before Umbrel run')
if install_pos('install_umbrel_safe_shutdown') > install_pos('wait_for_umbrel_runtime_health'):
    raise SystemExit('Order invariant failed: safe shutdown must be installed before runtime health')
if install_pos('wait_for_umbrel_runtime_health') > install_pos('info "Recording install state"'):
    raise SystemExit('Order invariant failed: runtime health must pass before install state recording')
source_branch = 'he==="shutting-down"&&!v&&(ce.isError||ce.failureCount>0)&&(b(!0),setTimeout(()=>S(!0),30*Kh))'
target_branch = 'he==="shutting-down"&&!v&&(b(!0),setTimeout(()=>S(!0),30*Kh))'
if text.count(f"source = '{source_branch}'") != 2 or text.count(f"target = '{target_branch}'") != 2:
    raise SystemExit('Installer must pin the exact 1.7.4 compiled shutdown UI source and target in patch and verify helpers')
if text.count('text.replace(source, target, 1)') != 1:
    raise SystemExit('Installer shutdown UI patch must replace exactly one compiled branch occurrence')
if 'd.useEffect(()=>{F==="shutting-down"' in text or '30*Gl' in text:
    raise SystemExit('Installer must not retain the obsolete local .tmp minified shutdown UI assumption')
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
    'UMBREL_IMAGE="dockurr/umbrel:1.7.4@sha256:e00c07a838ce3b50641a0a984abe155a7223abacab3426a55409edf21b6e0124"',
    'LEGACY_SYSTEM_CONTAINERS=(auth tor_proxy)',
    'CANDIDATE_SYSTEM_CONTAINERS=(umbrel_auth umbrel_tor_proxy)',
    'ALL_KNOWN_SYSTEM_CONTAINERS=("${LEGACY_SYSTEM_CONTAINERS[@]}" "${CANDIDATE_SYSTEM_CONTAINERS[@]}")',
    'TOR_PROXY_IMAGE="ghcr.io/getumbrel/tor:0.4.9.11"',
    'is_expected_tor_proxy_image',
    '@sha256:[0-9a-f]{64}',
    'UMBREL_TRANSACTION_TARGET_IMAGE_ID=""',
    'UMBREL_TRANSACTION_FAILURE_MESSAGE=""',
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
    'patch_umbrel_shutdown_ui',
    'verify_umbrel_shutdown_ui',
    'ce.isError||ce.failureCount>0',
    'he==="shutting-down"&&!v&&(b(!0),setTimeout(()=>S(!0),30*Kh))',
    'precheck_0_4_7_to_0_4_8',
    'apply_0_4_7_to_0_4_8',
    'postcheck_0_4_7_to_0_4_8',
    'precheck_0_4_8_to_0_4_9',
    'apply_0_4_8_to_0_4_9',
    'postcheck_0_4_8_to_0_4_9',
    'precheck_0_4_9_to_0_4_10',
    'apply_0_4_9_to_0_4_10',
    'postcheck_0_4_9_to_0_4_10',
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
    '0.5.18_to_0.5.19',
    '0.5.19_to_0.5.20',
    '0.5.20_to_0.5.21',
    '0.5.21_to_0.5.22',
    '0.5.22_to_0.5.23',
    '0.5.23_to_0.5.24',
    '0.5.24_to_0.5.25',
    'LEGACY_INCUS_PACKAGES=(incus incus-base incus-client lxd-agent-loader)',
    'cleanup_legacy_incus_lxd_remnants',
    'verify_legacy_incus_lxd_absent',
    'apt-get -o DPkg::Lock::Timeout=300 purge -y "${packages_to_purge[@]}"',
    'rm -rf -- "$path"',
    'is_system_container',
    'system_containers_need_replacement',
    'candidate_umbrel_container_ready',
    'candidate_system_containers_ready',
    'replace_system_containers',
    'rollback_umbrel_transaction',
    'fail_umbrel_transaction',
    'begin_umbrel_candidate_transaction',
    'complete_umbrel_transaction',
    'precheck_0_5_24_to_0_5_25',
    'apply_0_5_24_to_0_5_25',
    'postcheck_0_5_24_to_0_5_25',
    'last_attempted_image',
    'target_image',
    'runtime_image',
    'runtime_image_id',
    'expected_image_id="${UMBREL_TRANSACTION_TARGET_IMAGE_ID:-$(umbrel_image_id "$UMBREL_IMAGE")}"',
    'Refusing to finalize 0.5.25 because the live Umbrel image ref is not the candidate target.',
    'Refusing to finalize 0.5.25 because the live Umbrel image ID is not the resolved candidate.',
  ]
missing = [needle for needle in required if needle not in text]
if missing:
    print('Missing expected updater invariant text:')
    for needle in missing:
        print(f'  {needle}')
    raise SystemExit(1)

if 'UMBREL_IMAGE="dockurr/umbrel:1.7.3@sha256:' in text:
    raise SystemExit('Updater must not retain the old Dockur Umbrel 1.7.3 product pin')

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
if pos('if ! "$apply_fn"') > pos('mark_step_failed "$step" "${UMBREL_TRANSACTION_FAILURE_MESSAGE:-apply failed}"'):
    raise SystemExit('apply failure must be recorded before returning from step')
if pos('if ! "$postcheck_fn"') > pos('mark_step_failed "$step" "${UMBREL_TRANSACTION_FAILURE_MESSAGE:-postcheck failed}"'):
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
if 'restore_umbrel_shutdown_ui' in text or 'verify_umbrel_shutdown_ui_restored' in text:
    raise SystemExit('Updater must not restore the upstream error-gated shutdown UI branch')
source_branch = 'he==="shutting-down"&&!v&&(ce.isError||ce.failureCount>0)&&(b(!0),setTimeout(()=>S(!0),30*Kh))'
target_branch = 'he==="shutting-down"&&!v&&(b(!0),setTimeout(()=>S(!0),30*Kh))'
if text.count(f"source = '{source_branch}'") != 2 or text.count(f"target = '{target_branch}'") != 2:
    raise SystemExit('Updater must pin the exact 1.7.4 compiled shutdown UI source and target in patch and verify helpers')
if text.count('text.replace(source, target, 1)') != 1:
    raise SystemExit('Updater shutdown UI patch must replace exactly one compiled branch occurrence')
if '90*Gl' in text or 'm1s-shutdown-0.4.' in text:
    raise SystemExit('Updater must not restore historical cache-busted or 90-second shutdown UI branches')
if 'd.useEffect(()=>{F==="shutting-down"' in text or '30*Gl' in text:
    raise SystemExit('Updater must not retain the obsolete local .tmp minified shutdown UI assumption')
if safe.count('patch_umbrel_shutdown_ui') < 2:
    raise SystemExit('Safe shutdown install path must patch the compiled shutdown UI before restart and on retry')
if safe.count('verify_umbrel_shutdown_ui') < 3:
    raise SystemExit('Safe shutdown install/postcheck path must verify the compiled shutdown UI patch')
if pos('patch_umbrel_shutdown_ui', safe) > pos('docker restart --time 60 umbrel', safe):
    raise SystemExit('Compiled shutdown UI patch must be written before Umbrel is restarted into patched code')

refresh = text[pos('refresh_umbrel_system_container()'):]
transaction = text[pos('begin_umbrel_candidate_transaction()'):pos('wait_for_umbrel_http()')]
if pos('assert_fullnode_data_mount_safe', transaction) > pos('docker pull "$UMBREL_IMAGE"', transaction):
    raise SystemExit('Umbrel data mount safety check must happen before docker pull')
if pos('load_running_app_containers') > pos('UMBREL_TRANSACTION_APP_CONTAINERS=("${STOPPED_APP_CONTAINERS[@]}")'):
    raise SystemExit('Updater must capture running ordinary apps into transaction context')
if pos('is_system_container "$container" && continue') > pos('STOPPED_APP_CONTAINERS+=("$container")'):
    raise SystemExit('System containers must be excluded before ordinary app capture')
if pos('if [[ "$DRY_RUN" -eq 1 ]]', transaction) > pos('docker pull "$UMBREL_IMAGE"', transaction):
    raise SystemExit('Dry-run branch must return before docker pull mutates image cache')
if pos('docker pull "$UMBREL_IMAGE"', transaction) > pos('UMBREL_TRANSACTION_ACTIVE=1', transaction):
    raise SystemExit('Candidate image pull and ID resolution must happen before transaction becomes active')
if pos('UMBREL_TRANSACTION_ACTIVE=1', transaction) > pos('UMBREL_TRANSACTION_MUTATED=1', transaction):
    raise SystemExit('Transaction must become active before any container mutation is marked')
if pos('stop_running_app_containers', transaction) > pos('replace_system_containers', transaction):
    raise SystemExit('Ordinary app containers must stop before Umbrel-owned system containers are replaced')
if pos('replace_system_containers', transaction) > pos('docker stop umbrel', transaction):
    raise SystemExit('System containers must be replaced before the top-level umbrel container is stopped')
if pos('docker stop umbrel', transaction) > pos('docker rm umbrel', transaction):
    raise SystemExit('Top-level umbrel must stop before it is removed')
if pos('docker rm umbrel', transaction) > pos('run_umbrel_container_with_data_source "$UMBREL_IMAGE"', transaction):
    raise SystemExit('Top-level umbrel must be removed before candidate run')
if pos('run_umbrel_container_with_data_source "$UMBREL_IMAGE"', transaction) > pos('wait_for_umbrel_candidate_pre_health', transaction):
    raise SystemExit('Candidate pre-health must run after candidate container start')
rollback = text[pos('rollback_umbrel_transaction()'):pos('fail_umbrel_transaction()')]
if pos('for container in umbrel "${ALL_KNOWN_SYSTEM_CONTAINERS[@]}"', rollback) > pos('run_umbrel_container_with_data_source "$UMBREL_TRANSACTION_OLD_IMAGE_ID"', rollback):
    raise SystemExit('Rollback must remove candidate system stack before restarting old image')
postcheck_wait = text[pos('wait_for_postcheck_system_containers()'):pos('replace_system_containers()')]
for required in ['CANDIDATE_READINESS_ATTEMPTS', 'CANDIDATE_RETRY_DELAY_SECONDS', 'postcheck_system_containers_ready']:
    if required not in postcheck_wait:
        raise SystemExit('0.5.25 postcheck system readiness must reuse the bounded candidate retry contract')
postcheck_0525 = text[pos('postcheck_0_5_24_to_0_5_25()'):pos('# ---------------------------------------------------------------------------\n# Main flow')]
for predicate, observed_state in [
    ('mount-safety', 'not-safe'),
    ('top-level-readiness', 'not-ready'),
    ('system-container-readiness', 'not-ready'),
    ('safe-shutdown-verification', 'not-verified'),
    ('http-readiness', 'not-responsive'),
]:
    expected = f'report_candidate_postcheck_failure "{predicate}" "{observed_state}"'
    if expected not in postcheck_0525:
        raise SystemExit(f'0.5.25 postcheck must identify {predicate} failures with a generalized observed state')
if pos('candidate_umbrel_container_ready', postcheck_0525) > pos('wait_for_postcheck_system_containers', postcheck_0525):
    raise SystemExit('0.5.25 postcheck must verify top-level readiness before bounded system-container convergence')
if pos('wait_for_postcheck_system_containers', postcheck_0525) > pos('postcheck_umbrel_safe_shutdown', postcheck_0525):
    raise SystemExit('0.5.25 postcheck must verify system containers before safe-shutdown success')
if pos('postcheck_umbrel_safe_shutdown', postcheck_0525) > pos('wait_for_umbrel_http', postcheck_0525):
    raise SystemExit('0.5.25 postcheck must verify safe-shutdown before HTTP readiness completes the transaction')
if pos('fail_umbrel_transaction "candidate postcheck failed"', postcheck_0525) > pos('return 1', postcheck_0525):
    raise SystemExit('0.5.25 postcheck failure must roll back before returning failure')
finalize = text[pos('finalize_install_state()'):pos('is_step_applied()')]
finalize_0525_start = finalize.find('runtime_image="$(docker inspect umbrel --format')
if finalize_0525_start == -1:
    raise SystemExit('0.5.25 finalization must inspect the live Umbrel runtime image')
finalize_0525 = finalize[finalize_0525_start:]
if pos('docker inspect umbrel --format \'{{.Config.Image}}\'', finalize_0525) > pos('update_install_state finalized', finalize_0525):
    raise SystemExit('Finalization must derive image ref from live runtime before writing state')
if pos('docker inspect umbrel --format \'{{.Image}}\'', finalize_0525) > pos('update_install_state finalized', finalize_0525):
    raise SystemExit('Finalization must derive image ID from live runtime before writing state')
print('  ok updater preserves data-mount gates, check/dry-run path, 1.7.4 transaction rollback, and runtime-state invariants')
PY


printf '[verify] system package updater safety invariants\n'
python3 - <<'PY'
from pathlib import Path
text = Path('scripts/m1s-update-system-packages.sh').read_text(encoding='utf-8')
for forbidden in ['mkfs.', 'sfdisk', 'parted', 'wipefs', 'sgdisk', 'gdisk', 'blkdiscard', 'shred']:
    if forbidden in text:
        raise SystemExit(f'System package updater must never contain destructive disk command: {forbidden}')
required = [
    'SCRIPT_VERSION="0.5.25"',
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
    'actions/checkout@93cb6efe18208431cddfb8368fd83d5badbf9bfd',
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
    'bash scripts/check-public-scrub.sh',
    'Release notes scrub failed',
    'release notes expanded $(pwd) to this checkout path',
    r'safe\.directory="\$\(pwd\)"',
]
missing = [needle for needle in required if needle not in text]
if missing:
    print('Release gate is missing expected safety checks:')
    for needle in missing:
        print(f'  {needle}')
    raise SystemExit(1)
print('  ok release script gates tags/releases on clean tree, pushed HEAD, changelog, successful CI, and release-note scrub')
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
        'bash scripts/check-public-scrub.sh',
        'git ls-remote --exit-code --heads origin public-clean',
        'git push origin public-clean:main',
    ],
    'scripts/check-public-scrub.sh': [
        'PUBLIC_SCRUB_DENYLIST',
        'private IPv4 address',
        'MAC address',
        'local checkout path',
        'expanded safe.directory path',
        'public metadata scrub failed',
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
