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
  shellcheck_version_file=".shellcheck-version"
  if [[ ! -r "$shellcheck_version_file" ]]; then
    printf '  error ShellCheck version pin is missing: %s\n' "$shellcheck_version_file" >&2
    exit 1
  fi

  pinned_shellcheck_version="$(<"$shellcheck_version_file")"
  if [[ ! "$pinned_shellcheck_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    printf '  error Invalid ShellCheck version pin in %s: %s\n' "$shellcheck_version_file" "$pinned_shellcheck_version" >&2
    exit 1
  fi

  shellcheck_version_output="$(shellcheck --version)"
  shellcheck_found_version=""
  while IFS= read -r line; do
    if [[ "$line" == "version: "* ]]; then
      shellcheck_found_version="${line#version: }"
      break
    fi
  done <<< "$shellcheck_version_output"

  if [[ "$shellcheck_found_version" != "$pinned_shellcheck_version" ]]; then
    shellcheck_download_url="https://github.com/koalaman/shellcheck/releases/download/v${pinned_shellcheck_version}/shellcheck-v${pinned_shellcheck_version}.linux.x86_64.tar.xz"
    printf '  error ShellCheck version mismatch: pinned %s, found %s.\n' "$pinned_shellcheck_version" "${shellcheck_found_version:-unknown}" >&2
    printf '  Install ShellCheck %s from %s and ensure that binary is first on PATH.\n' "$pinned_shellcheck_version" "$shellcheck_download_url" >&2
    exit 1
  fi

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
expected_version = version
if not re.fullmatch(r'\d+\.\d+\.\d+', version):
    raise SystemExit(f'VERSION must be plain semver MAJOR.MINOR.PATCH, got {version!r}')

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

printf '[verify] bounded backup invariants\n'
python3 - <<'PY'
from pathlib import Path
import re

helper_path = Path('scripts/m1s-backup-retention.sh')
test_path = Path('tests/test-backup-retention.sh')
if not helper_path.exists():
    raise SystemExit(f'{helper_path} is missing')
if not test_path.exists():
    raise SystemExit(f'{test_path} is missing')

entrypoints = {
    Path('scripts/m1s-clean-install-umbrel.sh'): 6,
    Path('scripts/m1s-update-umbrel.sh'): 7,
}
source_line = 'source "$(dirname "${BASH_SOURCE[0]}")/m1s-backup-retention.sh"'
raw_backup_copy = re.compile(r'(?m)^[ \t]*(?!#)[^\n]*\bcp\b[^\n]*\.bak(?:\.|["\'])')
violations = []
for path, minimum_helper_calls in entrypoints.items():
    text = path.read_text(encoding='utf-8')
    if source_line not in text:
        violations.append(f'{path}: shared backup helper is not sourced')
    helper_calls = text.count('m1s_backup_file_with_retention ')
    if helper_calls < minimum_helper_calls:
        violations.append(
            f'{path}: expected at least {minimum_helper_calls} backup helper calls, found {helper_calls}'
        )
    for match in raw_backup_copy.finditer(text):
        line_number = text.count('\n', 0, match.start()) + 1
        violations.append(f'{path}:{line_number}: raw timestamped backup copy bypasses retention')

if violations:
    print('Bounded backup invariant failed:')
    for violation in violations:
        print(f'  {violation}')
    raise SystemExit(1)

print('  ok installer and updater route every timestamped backup through the shared bounded-retention helper')
PY

printf '[verify] Avahi mDNS invariants\n'
python3 - <<'PY'
from pathlib import Path
import re

helper_path = Path('scripts/m1s-avahi-mdns.sh')
test_path = Path('tests/test-avahi-mdns.sh')
entrypoints = (
    Path('scripts/m1s-clean-install-umbrel.sh'),
    Path('scripts/m1s-update-umbrel.sh'),
)
if not helper_path.exists():
    raise SystemExit(f'{helper_path} is missing')
if not test_path.exists():
    raise SystemExit(f'{test_path} is missing')

source_line = 'source "$(dirname "${BASH_SOURCE[0]}")/m1s-avahi-mdns.sh"'
helper_text = helper_path.read_text(encoding='utf-8')
script_texts = {
    path: path.read_text(encoding='utf-8')
    for path in sorted(Path('scripts').glob('*.sh'))
}
for path in entrypoints:
    if source_line not in script_texts[path]:
        raise SystemExit(f'{path}: shared Avahi helper is not sourced')

for path, text in script_texts.items():
    match = re.search(r'allow-interfaces\s*=', text)
    if match:
        line_number = text.count('\n', 0, match.start()) + 1
        raise SystemExit(f'{path}:{line_number}: script contains an active allow-interfaces writer')

definition_names = (
    'detect_lan_interface',
    'm1s_render_avahi_config',
    'm1s_render_avahi_alias_script',
    'm1s_render_avahi_alias_unit',
)
all_scripts = '\n'.join(script_texts.values())
for name in definition_names:
    count = len(re.findall(rf'(?m)^{re.escape(name)}\(\) \{{', all_scripts))
    if count != 1:
        raise SystemExit(f'{name} must have exactly one definition, found {count}')

installer_text = script_texts[entrypoints[0]]
installer_avahi = installer_text[
    installer_text.index('info "Setting up umbrel.local mDNS alias"'):
    installer_text.index('info "Recording install state"')
]
updater_text = script_texts[entrypoints[1]]
updater_avahi = '\n'.join((
    updater_text[updater_text.index('patch_to_0_3_0()'):updater_text.index('ensure_nvme_diagnostic_tools()')],
    updater_text[updater_text.index('patch_to_0_4_0()'):updater_text.index('patch_to_0_4_1()')],
    updater_text[updater_text.index('precheck_0_5_28_to_0_5_29()'):updater_text.index('# Main flow')],
))
for path, avahi_path in (
    (helper_path, helper_text),
    (entrypoints[0], installer_avahi),
    (entrypoints[1], updater_avahi),
):
    if re.search(r'\beth0\b', avahi_path):
        raise SystemExit(f'{path}: Avahi path hardcodes eth0')

for path in entrypoints:
    text = script_texts[path]
    for duplicate in ('avahi-publish-address -R umbrel.local', 'Description=Publish umbrel.local mDNS alias'):
        if duplicate in text:
            raise SystemExit(f'{path}: embedded Avahi alias script or unit duplicate remains')

print('  ok Avahi uses one shared renderer, has no active interface pin or fixed LAN interface, and keeps one alias source')
PY

printf '[verify] installer safety invariants\n'
python3 - <<'PY'
from pathlib import Path
import os
import re
import subprocess
import tempfile

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
    'enter_destructive_storage_window',
    'leave_destructive_storage_window',
    'assert_raw_disk_exclusive "$TARGET_DISK_PATH"',
    'systemctl mask --runtime "$unit"',
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

storage_flow = text[pos('info "Backing up /etc/fstab before modification"'):]
def storage_pos(needle: str) -> int:
    idx = storage_flow.find(needle)
    if idx == -1:
        raise SystemExit(f'Missing installer storage sequence text: {needle}')
    return idx

fstab_rewrite = storage_pos('info "Cleaning fstab entries that belong to RaspiBlitz eMMC setup"')
window_enter = storage_pos('\nenter_destructive_storage_window\n')
daemon_reload = storage_pos('\nrun_cmd systemctl daemon-reload\n')
generated_unit_stop = storage_pos('\nrun_cmd systemctl stop mnt-fullnode-swapfile.swap data.mount mnt-fullnode.mount || true\n')
first_cleanup_stop = storage_pos('\nstop_target_busy_processes\n')
unmount_section = storage_pos('run_shell "umount \'$DATA_DIR\' >/dev/null 2>&1 || true"')
if not (fstab_rewrite < window_enter < daemon_reload < generated_unit_stop < first_cleanup_stop < unmount_section):
    raise SystemExit('Order invariant failed: fstab cleanup must enter the destructive window, reload/stop stale generated units, then clean holders and unmount')

raw_repartition = text[pos('repartition_raw_disk()'):pos('resolve_block_path()')]
raw_stop = raw_repartition.find('\n  stop_target_busy_processes\n')
raw_assert = raw_repartition.find('\n  assert_raw_disk_exclusive "$TARGET_DISK_PATH"\n')
raw_sfdisk = raw_repartition.find('sfdisk --label gpt "$TARGET_DISK_PATH"')
if min(raw_stop, raw_assert, raw_sfdisk) == -1 or not (raw_stop < raw_assert < raw_sfdisk):
    raise SystemExit('Order invariant failed: final holder cleanup and exclusive-open assertion must precede raw-disk sfdisk')

window_helpers = text[pos('enter_destructive_storage_window()'):pos('assert_raw_disk_exclusive()')]
mask_lines = [line.strip() for line in window_helpers.splitlines() if 'systemctl mask' in line]
if not mask_lines or any('systemctl mask --runtime' not in line for line in mask_lines):
    raise SystemExit('Destructive storage window must use runtime-only systemd masks')
if re.search(r'(?m)\bsfdisk\b[^\n]*(?:--force|--no-reread)', text):
    raise SystemExit('Installer sfdisk invocations must never bypass in-use or partition-table reread safety')

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
public_branch = 'he==="shutting-down"&&!v&&(b(!0),setTimeout(()=>S(!0),30*Kh))'
canonical_branch = 'he==="shutting-down"&&!v&&(b(!0),setTimeout(()=>S(!0),75*Kh))'
required_shutdown_tokens = [
    f"SOURCE_ERROR_30 = '{source_branch}'",
    f"PUBLIC_STATUS_30 = '{public_branch}'",
    f"CANONICAL_STATUS_75 = '{canonical_branch}'",
    'SCRIPT_TAG_RE = re.compile',
    'LINK_TAG_RE = re.compile',
    'IMPORT_MAP_TAG_RE = re.compile',
    'ATTRIBUTE_RE = re.compile',
    'def has_managed_import_map_attribute(attributes):',
    "return 'data-m1s-shutdown-ui' in attributes",
    'def has_modulepreload_rel(attributes):',
    "return 'modulepreload' in attributes.get('rel', '').lower().split()",
    'EXECUTABLE_SCRIPT_TYPES',
    'ASSET_REF_RE = re.compile',
    'def executable_script_candidates(index_text):',
    'def module_graph_trigger_starts(index_text, executable_candidates):',
    'expected exactly one executable index script reference',
    'ASSET_REF_RE.fullmatch(ref)',
    'attribute_spans = {}',
    "script_tag.start('attrs') + attribute_spans['src'][0]",
    'selected executable script reference does not match its index span',
    "json.dumps({'imports': {original_ref: target_ref}}, separators=(',', ':'))",
    'def import_map_candidates(index_text):',
    'managed import map does not exactly map the original entry to the generated entry',
    'rewritten_index_text = index_text[:ref_start] + new_ref + index_text[ref_end:]',
    'trigger_starts = module_graph_trigger_starts(index_text, candidates)',
    'insertion_start = min(trigger_starts)',
    'new_index_text = rewritten_index_text[:insertion_start] + managed_import_map_tag(ref, new_ref)',
    'HASHED_NAME_RE = re.compile',
    'hashlib.sha256(patched_bytes).hexdigest()[:12]',
    "new_name = f'{base_stem}.m1s-{digest}.js'",
    "new_ref = f'/assets/{new_name}'",
    'atomic_write(new_path, patched_bytes)',
    'atomic_write(INDEX, new_index_text.encode',
]
missing_shutdown_tokens = [token for token in required_shutdown_tokens if token not in text]
if missing_shutdown_tokens:
    raise SystemExit(f'Installer shutdown UI patch is missing content-hash/index binding tokens: {missing_shutdown_tokens}')
if 'index_text.replace(ref, new_ref, 1)' in text:
    raise SystemExit('Installer must rewrite only the selected executable script src span')
if 'MANAGED_IMPORT_MAP_ATTR_' + 'RE' in text:
    raise SystemExit('Installer must determine managed import maps from parsed attribute names')
if 'managed import map must precede module execution' in text:
    raise SystemExit('Installer must require the managed import map before every module graph trigger')
if 'path.write_text(text.replace(source, target, 1))' in text or "target = 'he===\"shutting-down\"&&!v&&(b(!0),setTimeout(()=>S(!0),30*Kh))'" in text:
    raise SystemExit('Installer must not mutate the old asset in place or keep the 30-second branch as canonical')
if 'd.useEffect(()=>{F==="shutting-down"' in text or '30*Gl' in text:
    raise SystemExit('Installer must not retain the obsolete local .tmp minified shutdown UI assumption')
print('  ok installer safety invariants and critical ordering')

with tempfile.TemporaryDirectory(prefix='m1s-exclusive-gate-') as temp_dir_name:
    temp_dir = Path(temp_dir_name)
    fake_bin = temp_dir / 'bin'
    fake_bin.mkdir()
    sfdisk_record = temp_dir / 'sfdisk-called'
    probe = temp_dir / 'exclusive-probe'
    probe.write_text('#!/usr/bin/env bash\nexit 75\n', encoding='utf-8')
    probe.chmod(0o755)

    fake_sfdisk = fake_bin / 'sfdisk'
    fake_sfdisk.write_text(
        '#!/usr/bin/env bash\nprintf invoked > "$SFDISK_RECORD"\n',
        encoding='utf-8',
    )
    fake_sfdisk.chmod(0o755)
    for command_name in ('findmnt', 'swapon', 'fuser', 'systemctl'):
        fake_command = fake_bin / command_name
        fake_command.write_text('#!/usr/bin/env bash\nexit 0\n', encoding='utf-8')
        fake_command.chmod(0o755)

    environment = os.environ.copy()
    environment.update({
        'INSTALLER_UNDER_TEST': str(Path('scripts/m1s-clean-install-umbrel.sh').resolve()),
        'M1S_INSTALLER_LIB_ONLY': '1',
        'M1S_EXCLUSIVE_PROBE_COMMAND': str(probe),
        'PATH': f'{fake_bin}:{environment["PATH"]}',
        'SFDISK_RECORD': str(sfdisk_record),
    })
    result = subprocess.run(
        [
            'bash',
            '-c',
            '''set -Eeuo pipefail
source "$INSTALLER_UNDER_TEST"
stop_target_busy_processes() { :; }
TARGET_DISK_PATH="/dev/m1s-exclusive-test"
TARGET_PARTITION="/dev/m1s-exclusive-testp1"
DATA_DIR="/mnt/fullnode"
DRY_RUN=0
repartition_raw_disk
''',
        ],
        env=environment,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )
    if result.returncode == 0:
        raise SystemExit('Exclusive-open gate test expected the raw-disk repartition region to fail on probe exit 75')
    if sfdisk_record.exists():
        raise SystemExit('Exclusive-open gate test invoked fake sfdisk after probe exit 75')
    if 'was re-claimed after cleanup' not in result.stderr:
        raise SystemExit('Exclusive-open gate test did not emit the hard-failure re-claimed diagnostic')
    print('  ok exclusive-open EBUSY gate blocks raw-disk sfdisk')
PY

printf '[verify] updater safety invariants\n'
python3 - <<'PY'
from pathlib import Path
import re
text = Path('scripts/m1s-update-umbrel.sh').read_text(encoding='utf-8')
lifecycle = Path('scripts/m1s-docker-lifecycle.sh').read_text(encoding='utf-8')
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
    'm1s_docker_lifecycle_stop STOPPED_APP_CONTAINERS "$APP_STOP_TIMEOUT_SECONDS"',
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
    'SOURCE_ERROR_30',
    'PUBLIC_STATUS_30',
    'CANONICAL_STATUS_75',
    'SCRIPT_TAG_RE = re.compile',
    'LINK_TAG_RE = re.compile',
    'IMPORT_MAP_TAG_RE = re.compile',
    'ATTRIBUTE_RE = re.compile',
    'def has_managed_import_map_attribute(attributes):',
    "return 'data-m1s-shutdown-ui' in attributes",
    'def has_modulepreload_rel(attributes):',
    "return 'modulepreload' in attributes.get('rel', '').lower().split()",
    'EXECUTABLE_SCRIPT_TYPES',
    'ASSET_REF_RE = re.compile',
    'def executable_script_candidates(index_text):',
    'def module_graph_trigger_starts(index_text, executable_candidates):',
    'expected exactly one executable index script reference',
    'ASSET_REF_RE.fullmatch(ref)',
    'attribute_spans = {}',
    "script_tag.start('attrs') + attribute_spans['src'][0]",
    'selected executable script reference does not match its index span',
    "json.dumps({'imports': {original_ref: target_ref}}, separators=(',', ':'))",
    'def import_map_candidates(index_text):',
    'managed import map does not exactly map the original entry to the generated entry',
    'rewritten_index_text = index_text[:ref_start] + new_ref + index_text[ref_end:]',
    'trigger_starts = module_graph_trigger_starts(index_text, candidates)',
    'insertion_start = min(trigger_starts)',
    'new_index_text = rewritten_index_text[:insertion_start] + managed_import_map_tag(ref, new_ref)',
    'he==="shutting-down"&&!v&&(b(!0),setTimeout(()=>S(!0),75*Kh))',
    'hashlib.sha256(patched_bytes).hexdigest()[:12]',
    "new_name = f'{base_stem}.m1s-{digest}.js'",
    'atomic_write(new_path, patched_bytes)',
    'atomic_write(INDEX, new_index_text.encode',
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
    '0.5.25_to_0.5.26',
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
    'precheck_0_5_25_to_0_5_26',
    'apply_0_5_25_to_0_5_26',
    'postcheck_0_5_25_to_0_5_26',
    'last_attempted_image',
    'target_image',
    'runtime_image',
    'runtime_image_id',
    'verified_umbrel_runtime_snapshot',
    'VERIFIED_UMBREL_RUNTIME_IMAGE',
    'VERIFIED_UMBREL_RUNTIME_IMAGE_ID',
    'skips live Umbrel runtime verification and final state publication',
    'Refusing to finalize because the live Umbrel runtime image reference could not be verified.',
    'Refusing to finalize because the live Umbrel runtime image ID could not be verified.',
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
public_branch = 'he==="shutting-down"&&!v&&(b(!0),setTimeout(()=>S(!0),30*Kh))'
canonical_branch = 'he==="shutting-down"&&!v&&(b(!0),setTimeout(()=>S(!0),75*Kh))'
required_shutdown_tokens = [
    f"SOURCE_ERROR_30 = '{source_branch}'",
    f"PUBLIC_STATUS_30 = '{public_branch}'",
    f"CANONICAL_STATUS_75 = '{canonical_branch}'",
    'IMPORT_MAP_TAG_RE = re.compile',
    'LINK_TAG_RE = re.compile',
    'def has_managed_import_map_attribute(attributes):',
    "return 'data-m1s-shutdown-ui' in attributes",
    'def has_modulepreload_rel(attributes):',
    "return 'modulepreload' in attributes.get('rel', '').lower().split()",
    'def module_graph_trigger_starts(index_text, executable_candidates):',
    'def import_map_candidates(index_text):',
    "json.dumps({'imports': {original_ref: target_ref}}, separators=(',', ':'))",
    'managed import map must precede every module graph trigger',
    'managed import map does not exactly map the original entry to the generated entry',
    'ASSET_REF_RE = re.compile',
    'HASHED_NAME_RE = re.compile',
    'hashlib.sha256(patched_bytes).hexdigest()[:12]',
    "new_name = f'{base_stem}.m1s-{digest}.js'",
    "new_ref = f'/assets/{new_name}'",
    'atomic_write(new_path, patched_bytes)',
    'atomic_write(INDEX, new_index_text.encode',
]
missing_shutdown_tokens = [token for token in required_shutdown_tokens if token not in text]
if missing_shutdown_tokens:
    raise SystemExit(f'Updater shutdown UI patch is missing content-hash/index binding tokens: {missing_shutdown_tokens}')
if 'index_text.replace(ref, new_ref, 1)' in text:
    raise SystemExit('Updater must rewrite only the selected executable script src span')
if 'MANAGED_IMPORT_MAP_ATTR_' + 'RE' in text:
    raise SystemExit('Updater must determine managed import maps from parsed attribute names')
if 'managed import map must precede module execution' in text:
    raise SystemExit('Updater must require the managed import map before every module graph trigger')
if 'path.write_text(text.replace(source, target, 1))' in text or "target = 'he===\"shutting-down\"&&!v&&(b(!0),setTimeout(()=>S(!0),30*Kh))'" in text:
    raise SystemExit('Updater must not mutate the old asset in place or keep the 30-second branch as canonical')
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
if pos('! "$predicate_name" "$container"', lifecycle) > pos('containers_ref+=("$container")', lifecycle):
    raise SystemExit('System containers must be excluded before ordinary app capture')
if '[[ "$container" != "umbrel" ]] && ! is_system_container "$container"' not in text:
    raise SystemExit('Updater must exclude top-level and system containers before ordinary app capture')
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
snapshot = text[pos('verified_umbrel_runtime_snapshot()'):pos('finalize_install_state()')]
candidate_ready = text[pos('candidate_umbrel_container_ready()'):pos('candidate_system_containers_ready()')]
configured_ref_helper = text[
    pos('umbrel_image_ref_resolves_to_image_id()'):pos('run_umbrel_container_with_data_source()')
]
finalize = text[pos('finalize_install_state()'):pos('is_step_applied()')]
if '0.5.25' in finalize or re.search(r'if \[\[ .*\bversion\b.*(?:==|!=|=~)', finalize):
    raise SystemExit('Finalization must not special-case a target version')
for required in [
    '[[ -n "$image_ref" && -n "$expected_image_id" ]] || return 1',
    'resolved_image_id="$(docker image inspect "$image_ref" --format \'{{.Id}}\' 2>/dev/null || true)"',
    '[[ "$resolved_image_id" == "$expected_image_id" ]]',
]:
    if required not in configured_ref_helper:
        raise SystemExit(f'Configured image-ref proof is missing required verification: {required}')
for required in [
    'runtime_image="$(docker inspect umbrel --format \'{{.Config.Image}}\' 2>/dev/null || true)"',
    'runtime_image_id="$(docker inspect umbrel --format \'{{.Image}}\' 2>/dev/null || true)"',
    'expected_image_id="$(umbrel_image_id "$UMBREL_IMAGE")"',
    '[[ -n "$runtime_image" ]]',
    '[[ -n "$expected_image_id" && -n "$runtime_image_id" && "$runtime_image_id" == "$expected_image_id" ]]',
    'umbrel_image_ref_resolves_to_image_id "$runtime_image" "$expected_image_id"',
    'VERIFIED_UMBREL_RUNTIME_IMAGE="$UMBREL_IMAGE"',
    'VERIFIED_UMBREL_RUNTIME_IMAGE_ID="$runtime_image_id"',
]:
    if required not in snapshot:
        raise SystemExit(f'Live runtime snapshot is missing required verification: {required}')
for required in [
    '[[ "$image_id" == "$expected_image_id" ]]',
    'umbrel_image_ref_resolves_to_image_id "$image_ref" "$expected_image_id"',
]:
    if required not in candidate_ready:
        raise SystemExit(f'Candidate readiness is missing required configured-ref verification: {required}')
if pos('docker inspect umbrel --format \'{{.Config.Image}}\'', snapshot) > pos('VERIFIED_UMBREL_RUNTIME_IMAGE="$UMBREL_IMAGE"', snapshot):
    raise SystemExit('Live runtime image ref must be read before the verified snapshot is published')
if pos('docker inspect umbrel --format \'{{.Image}}\'', snapshot) > pos('VERIFIED_UMBREL_RUNTIME_IMAGE_ID="$runtime_image_id"', snapshot):
    raise SystemExit('Live runtime image ID must be read before the verified snapshot is published')
if pos('expected_image_id="$(umbrel_image_id "$UMBREL_IMAGE")"', snapshot) > pos('VERIFIED_UMBREL_RUNTIME_IMAGE_ID="$runtime_image_id"', snapshot):
    raise SystemExit('Pinned Umbrel image ID must resolve before the verified snapshot is published')
if pos('umbrel_image_ref_resolves_to_image_id "$runtime_image" "$expected_image_id"', snapshot) > pos('VERIFIED_UMBREL_RUNTIME_IMAGE="$UMBREL_IMAGE"', snapshot):
    raise SystemExit('Configured runtime image ref must resolve to the expected ID before canonical image metadata is published')
if finalize.count('update_install_state finalized') != 1:
    raise SystemExit('Finalization must publish install state through exactly one finalized update')
if pos('if [[ "$DRY_RUN" -eq 1 ]]', finalize) > pos('verified_umbrel_runtime_snapshot', finalize):
    raise SystemExit('Dry-run must skip live runtime verification before finalization can inspect Docker')
if pos('verified_umbrel_runtime_snapshot', finalize) > pos('update_install_state finalized', finalize):
    raise SystemExit('Every target finalization must verify the live runtime snapshot before state publication')
if 'update_install_state finalized "" "$version" "" "$VERIFIED_UMBREL_RUNTIME_IMAGE" "$VERIFIED_UMBREL_RUNTIME_IMAGE_ID"' not in finalize:
    raise SystemExit('Finalization must atomically publish version and verified runtime metadata together')

def runtime_contract_failure(message: str) -> None:
    raise SystemExit(f'Runtime-truth control-flow contract failed: {message}')

PROTECTED_FUNCTION_SUCCESSORS = {
    'verify_umbrel_runtime_truth': 'finalize_install_state',
    'finalize_install_state': 'report_umbrel_runtime_truth',
    'report_umbrel_runtime_truth': 'install_state_matches_verified_runtime',
    'repair_current_umbrel_runtime': 'reconcile_current_version_runtime',
    'reconcile_current_version_runtime': 'is_step_applied',
}

def function_body(source: str, name: str) -> str:
    header = re.search(rf'(?m)^{re.escape(name)}\(\) \{{\n', source)
    if not header:
        runtime_contract_failure(f'missing function body: {name}')
    start = header.end()
    successor = PROTECTED_FUNCTION_SUCCESSORS.get(name)
    if successor:
        boundary = re.search(rf'(?m)^{re.escape(successor)}\(\) \{{\n', source[start:])
        if not boundary:
            runtime_contract_failure(f'missing protected successor for function: {name}')
        end = start + boundary.start()
    else:
        boundary = re.search(
            r'(?m)^if \[\[ "\$\{BASH_SOURCE\[0\]\}" == "\$0" \]\]; then\n',
            source[start:],
        )
        if not boundary:
            runtime_contract_failure(f'missing protected main guard after function: {name}')
        end = start + boundary.start()
    enclosed = source[start:end]
    closing = re.search(r'(?s)^(?P<body>.*)\n}\s*\Z', enclosed)
    if not closing:
        runtime_contract_failure(f'function body has no isolated closing brace: {name}')
    body = closing.group('body')
    if re.search(
        r'(?m)^[ \t]*(?:function[ \t]+)?[A-Za-z_][A-Za-z0-9_]*[ \t]*\(\)[ \t]*\{',
        body,
    ):
        runtime_contract_failure(f'protected function must not declare nested functions: {name}')
    return body

def executable_code(source: str) -> str:
    output = ['\n' if char == '\n' else ' ' for char in source]
    length = len(source)

    def walk(index: int, terminator: str | None = None) -> int:
        while index < length:
            char = source[index]
            if terminator and char == terminator:
                output[index] = char
                return index + 1
            if char == '#':
                while index < length and source[index] != '\n':
                    index += 1
                continue
            if char == '\\':
                output[index] = char
                if index + 1 < length:
                    output[index + 1] = source[index + 1]
                index += 2
                continue
            if char == "'":
                index += 1
                while index < length and source[index] != "'":
                    index += 1
                index += 1
                continue
            if char == '"':
                index += 1
                while index < length and source[index] != '"':
                    if source[index] == '\\':
                        index += 2
                    elif source.startswith('$(', index):
                        output[index:index + 2] = '$('
                        index = walk(index + 2, ')')
                    elif source[index] == '$':
                        variable = re.match(
                            r'\$(?:\{[^}\n]*\}|[A-Za-z_][A-Za-z0-9_]*)',
                            source[index:],
                        )
                        if variable:
                            end = index + variable.end()
                            output[index:end] = source[index:end]
                            index = end
                        else:
                            index += 1
                    elif source[index] == '`':
                        output[index] = '`'
                        index = walk(index + 1, '`')
                    else:
                        index += 1
                index += 1
                continue
            if source.startswith('$(', index):
                output[index:index + 2] = '$('
                index = walk(index + 2, ')')
                continue
            if char == '`':
                output[index] = '`'
                index = walk(index + 1, '`')
                continue
            output[index] = char
            index += 1
        if terminator:
            runtime_contract_failure(f'unclosed executable substitution: {terminator}')
        return index

    walk(0)
    return ''.join(output)

def executable_call_positions(source: str, call: str) -> list[int]:
    code = executable_code(source)
    pattern = re.compile(
        rf'(?mx)(?:^|[;|&(){{}}]|\b(?:then|do|else|elif|if)\b)'
        rf'[ \t]*(?:![ \t]*)?(?P<call>{re.escape(call)})'
        rf'(?![A-Za-z0-9_])(?![ \t]*\(\)[ \t]*\{{)'
    )
    return [match.start('call') for match in pattern.finditer(code)]


def executable_commands(source: str) -> list[str]:
    code = executable_code(source)
    shell_keywords = r'(?:if|then|fi|elif|else|for|while|until|case|esac|do|done|in|function)'
    pattern = re.compile(
        r'(?mx)(?:^|[;|&(){}]|`|\b(?:then|do|else|elif|if)\b)'
        r'[ \t]*(?:![ \t]*)?'
        r'(?:(?:[A-Za-z_][A-Za-z0-9_]*=[^ \t;|&(){}\n`]*)[ \t]+)*'
        r'(?P<command>'
        r'\$(?:\{[^}\n]*\}|[A-Za-z_][A-Za-z0-9_]*)'
        rf'|(?!(?:{shell_keywords})\b)(?![A-Za-z_][A-Za-z0-9_]*=)[A-Za-z_][A-Za-z0-9_]*'
        r')'
    )
    return [match.group('command') for match in pattern.finditer(code)]


def require_approved_commands(source: str, label: str, allowed: frozenset[str]) -> None:
    unexpected = sorted(set(executable_commands(source)) - allowed)
    if unexpected:
        runtime_contract_failure(
            f'{label} must not invoke unapproved command: {unexpected[0]}'
        )

def require_executable_call(source: str, call: str, message: str) -> int:
    positions = executable_call_positions(source, call)
    if not positions:
        runtime_contract_failure(message)
    return positions[0]

def if_block(source: str, condition: str, label: str) -> tuple[str, int, int]:
    code = executable_code(source)
    header = re.search(
        rf'(?m)^[ \t]*if[ \t]+{condition}[ \t]*;[ \t]*then\b',
        code,
    )
    if not header:
        runtime_contract_failure(f'missing {label} route')
    depth = 0
    for token in re.finditer(r'\b(?:if|fi)\b', code[header.start():]):
        if token.group(0) == 'if':
            depth += 1
        else:
            depth -= 1
            if depth == 0:
                closing_start = header.start() + token.start()
                closing_end = header.start() + token.end()
                return source[header.end():closing_start], header.start(), closing_end
    runtime_contract_failure(f'unclosed {label} route')

def simple_branch_statements(source: str, label: str) -> list[tuple[str, str]]:
    code = executable_code(source)
    if re.search(
        r'\b(?:if|then|fi|elif|else|for|while|until|case|esac|do|done|function)\b|[|&(){}]',
        code,
    ):
        runtime_contract_failure(f'{label} route must use only simple allowlisted statements')
    statements = []
    for raw_statement in re.split(r'[;\n]', code):
        statement = raw_statement.strip()
        if not statement:
            continue
        match = re.fullmatch(
            r'(?P<command>[A-Za-z_][A-Za-z0-9_]*)(?:[ \t]+(?P<args>.*?))?',
            statement,
        )
        if not match:
            runtime_contract_failure(f'{label} route has unsupported executable syntax')
        statements.append((match.group('command'), (match.group('args') or '').strip()))
    return statements

def reject_dynamic_dispatch(source: str, label: str) -> None:
    code = executable_code(source)
    command_prefix = r'(?mx)(?:^|[;|&(){}]|\b(?:then|do|else|elif|if)\b)[ \t]*(?:![ \t]*)?'
    variable = re.search(
        command_prefix + r'(?P<command>\$(?:\{[^}\n]*\}|[A-Za-z_][A-Za-z0-9_]*))',
        code,
    )
    if variable:
        runtime_contract_failure(
            f'{label} must not use dynamic command dispatch: variable invocation'
        )
    launcher = re.search(
        command_prefix + r'(?P<command>eval|builtin|command|bash|sh|source|xargs|\.)'
        r'(?![A-Za-z0-9_])',
        code,
    )
    if launcher:
        runtime_contract_failure(
            f'{label} must not use dynamic command dispatch: {launcher.group("command")}'
        )

def validate_runtime_truth_control_flow(source: str) -> None:
    snapshot = source[source.index('verified_umbrel_runtime_snapshot()'):source.index('finalize_install_state()')]
    verifier = function_body(source, 'verify_umbrel_runtime_truth')
    finalize_body = function_body(source, 'finalize_install_state')
    repair = function_body(source, 'repair_current_umbrel_runtime')
    reconcile = function_body(source, 'reconcile_current_version_runtime')
    report = function_body(source, 'report_umbrel_runtime_truth')
    main_body = function_body(source, 'main')

    if executable_commands('data_source=canonical\n'):
        runtime_contract_failure('executable command extraction must ignore assignments')
    if executable_commands('data_source="$(inspect_umbrel_mount_source /data)"\n') != [
        'inspect_umbrel_mount_source'
    ]:
        runtime_contract_failure('executable command extraction must retain command substitutions')
    if executable_commands('value=`umbrel_image_id "$UMBREL_IMAGE"`\n') != [
        'umbrel_image_id'
    ]:
        runtime_contract_failure('executable command extraction must retain backtick substitutions')
    if executable_commands('if true; then nested_runtime_check; fi\n') != [
        'true',
        'nested_runtime_check',
    ]:
        runtime_contract_failure('executable command extraction must retain inline nested commands')
    if 'umbrel_image_ref_resolves_to_image_id "$runtime_image" "$expected_image_id"' not in snapshot:
        runtime_contract_failure(
            'runtime snapshot must prove the configured image ref resolves to the expected immutable ID'
        )
    if 'VERIFIED_UMBREL_RUNTIME_IMAGE="$UMBREL_IMAGE"' not in snapshot:
        runtime_contract_failure(
            'runtime snapshot must publish the canonical configured Umbrel image ref'
        )

    allowed_commands = {
        'verify_umbrel_runtime_truth': frozenset({
            'assert_fullnode_data_mount_safe',
            'candidate_umbrel_container_ready',
            'docker',
            'inspect_umbrel_mount_source',
            'local',
            'postcheck_umbrel_safe_shutdown',
            'report_umbrel_runtime_truth_failure',
            'return',
            'system_containers_need_replacement',
            'true',
            'umbrel_image_id',
            'verified_umbrel_runtime_snapshot',
            'wait_for_umbrel_http',
        }),
        'finalize_install_state': frozenset({
            'echo',
            'local',
            'return',
            'update_install_state',
            'verified_umbrel_runtime_snapshot',
            'verify_umbrel_runtime_truth',
        }),
        'report_umbrel_runtime_truth': frozenset({
            'info',
            'return',
            'verify_umbrel_runtime_truth',
        }),
        'repair_current_umbrel_runtime': frozenset({
            'assert_fullnode_data_mount_safe',
            'begin_umbrel_candidate_transaction',
            'complete_umbrel_transaction',
            'err',
            'fail_umbrel_transaction',
            'install_umbrel_safe_shutdown',
            'return',
            'verify_umbrel_runtime_truth',
            'wait_for_postcheck_system_containers',
        }),
        'reconcile_current_version_runtime': frozenset({
            'finalize_install_state',
            'info',
            'install_state_matches_verified_runtime',
            'local',
            'repair_current_umbrel_runtime',
            'report_umbrel_runtime_truth',
            'return',
        }),
    }
    for label, body in (
        ('verify_umbrel_runtime_truth', verifier),
        ('finalize_install_state', finalize_body),
        ('report_umbrel_runtime_truth', report),
        ('repair_current_umbrel_runtime', repair),
        ('reconcile_current_version_runtime', reconcile),
    ):
        reject_dynamic_dispatch(body, label)
    reject_dynamic_dispatch(main_body, 'main')

    required_predicate_calls = (
        'verified_umbrel_runtime_snapshot',
        'assert_fullnode_data_mount_safe',
        'candidate_umbrel_container_ready',
        'system_containers_need_replacement',
        'postcheck_umbrel_safe_shutdown',
        'wait_for_umbrel_http',
    )
    for call in required_predicate_calls:
        require_executable_call(
            verifier,
            call,
            f'full runtime verifier must compose executable predicate: {call}',
        )
    for mount in ('/data', '/var/run/docker.sock'):
        require_executable_call(
            verifier,
            f'inspect_umbrel_mount_source {mount}',
            f'full runtime verifier must compose executable predicate: inspect_umbrel_mount_source {mount}',
        )

    snapshot_position = require_executable_call(
        finalize_body,
        'verified_umbrel_runtime_snapshot',
        'finalize_install_state must prove the live runtime snapshot',
    )
    full_verifier_position = require_executable_call(
        finalize_body,
        'verify_umbrel_runtime_truth',
        'finalize_install_state must invoke full runtime truth verification',
    )
    publication_positions = executable_call_positions(
        finalize_body,
        'update_install_state finalized',
    )
    if len(publication_positions) != 1:
        runtime_contract_failure(
            'finalize_install_state must contain exactly one final state publication'
        )
    if len(executable_call_positions(source, 'update_install_state finalized')) != 1:
        runtime_contract_failure(
            'no image-only publication path may exist outside finalize_install_state'
        )
    publication_position = publication_positions[0]
    if snapshot_position > full_verifier_position:
        runtime_contract_failure(
            'runtime snapshot must precede full runtime truth verification in finalization'
        )
    if full_verifier_position > publication_position:
        runtime_contract_failure(
            'full runtime truth verification must precede final state publication'
        )

    newer_body, newer_start, _ = if_block(
        main_body,
        r'version_lt[ \t]+\$TARGET_VERSION[ \t]+\$CURRENT_VERSION',
        'current>target',
    )
    equal_body, equal_start, _ = if_block(
        main_body,
        r'\[\[[ \t]+\$\{#PLANNED_MIGRATIONS\[@\]\}[ \t]+-eq[ \t]+0[ \t]+\]\]',
        'current==target',
    )
    if newer_start > equal_start:
        runtime_contract_failure('current>target route must precede the current==target route')
    newer_mutators = (
        'reconcile_current_version_runtime',
        'repair_current_umbrel_runtime',
        'begin_umbrel_candidate_transaction',
        'ensure_fullnode_mount_from_state',
        'global_preflight',
        'run_migration_step',
        'finalize_install_state',
        'update_install_state',
    )
    for mutator in newer_mutators:
        if executable_call_positions(newer_body, mutator):
            runtime_contract_failure(
                f'current>target route must not call mutator: {mutator}'
            )
    main_mutation_calls = (
        'reconcile_current_version_runtime',
        'ensure_fullnode_mount_from_state',
        'global_preflight',
        'run_migration_step',
        'finalize_install_state',
    )
    for call in main_mutation_calls:
        position = require_executable_call(
            main_body,
            call,
            f'main flow must retain runtime/state operation: {call}',
        )
        if newer_start > position:
            runtime_contract_failure(
                f'current>target route must precede mount/runtime/state operation: {call}'
            )
    if not executable_call_positions(equal_body, 'reconcile_current_version_runtime'):
        runtime_contract_failure(
            'current==target route must reconcile runtime truth after newer-version return'
        )
    if simple_branch_statements(newer_body, 'current>target') != [('echo', ''), ('return', '0')]:
        runtime_contract_failure('current>target route must return without mutation')
    if simple_branch_statements(equal_body, 'current==target') != [
        ('reconcile_current_version_runtime', '$TARGET_VERSION'),
        ('return', ''),
    ]:
        runtime_contract_failure('current==target route must return through reconciliation')

    require_executable_call(
        report,
        'verify_umbrel_runtime_truth',
        'report-only runtime truth must invoke the full runtime verifier',
    )
    for mutator in (
        'repair_current_umbrel_runtime',
        'begin_umbrel_candidate_transaction',
        'finalize_install_state',
        'update_install_state',
        'ensure_fullnode_mount_from_state',
    ):
        if executable_call_positions(report, mutator):
            runtime_contract_failure(
                f'report-only runtime truth must not call mutator: {mutator}'
            )

    check_body, _, check_end = if_block(
        reconcile,
        r'\[\[[ \t]+\$CHECK_ONLY[ \t]+-eq[ \t]+1[ \t]+\]\]',
        'CHECK_ONLY reconciliation',
    )
    check_mutators = (
        'repair_current_umbrel_runtime',
        'begin_umbrel_candidate_transaction',
        'finalize_install_state',
        'update_install_state',
        'ensure_fullnode_mount_from_state',
    )
    for mutator in check_mutators:
        if executable_call_positions(check_body, mutator):
            runtime_contract_failure(
                f'CHECK_ONLY route must not call mutator: {mutator}'
            )
    check_report_position = require_executable_call(
        check_body,
        'report_umbrel_runtime_truth',
        'CHECK_ONLY route must report full runtime truth',
    )
    check_return_position = require_executable_call(
        check_body,
        'return',
        'CHECK_ONLY route must return after report-only runtime truth',
    )
    if check_report_position > check_return_position:
        runtime_contract_failure('CHECK_ONLY route must report runtime truth before returning')
    if simple_branch_statements(check_body, 'CHECK_ONLY') != [
        ('report_umbrel_runtime_truth', ''),
        ('return', ''),
    ]:
        runtime_contract_failure('CHECK_ONLY route must return after report-only runtime truth')
    for call in ('repair_current_umbrel_runtime', 'finalize_install_state'):
        position = require_executable_call(
            reconcile,
            call,
            f'reconciliation must retain apply-mode operation: {call}',
        )
        if position < check_end:
            runtime_contract_failure(
                f'CHECK_ONLY route must return before reconciliation operation: {call}'
            )

    identity_position = require_executable_call(
        repair,
        'assert_fullnode_data_mount_safe',
        'repair_current_umbrel_runtime must prove data identity',
    )
    transaction_positions = executable_call_positions(
        repair,
        'begin_umbrel_candidate_transaction',
    )
    if len(transaction_positions) != 1:
        runtime_contract_failure(
            'repair_current_umbrel_runtime must begin exactly one forced repair transaction'
        )
    transaction_position = transaction_positions[0]
    if identity_position > transaction_position:
        runtime_contract_failure(
            'repair_current_umbrel_runtime must prove data identity before forced repair'
        )
    if not executable_call_positions(repair, 'begin_umbrel_candidate_transaction 1'):
        runtime_contract_failure(
            'repair_current_umbrel_runtime must use the forced candidate transaction exactly once'
        )
    safe_shutdown_position = require_executable_call(
        repair,
        'install_umbrel_safe_shutdown',
        'repair_current_umbrel_runtime must install safe shutdown during repair',
    )
    repair_wait_positions = executable_call_positions(
        repair,
        'wait_for_postcheck_system_containers',
    )
    if len(repair_wait_positions) != 1:
        runtime_contract_failure(
            'repair_current_umbrel_runtime must wait exactly once after safe-shutdown installation'
        )
    repair_wait_position = repair_wait_positions[0]
    repair_verifier_position = require_executable_call(
        repair,
        'verify_umbrel_runtime_truth',
        'repair_current_umbrel_runtime must fully re-verify after repair',
    )
    completion_position = require_executable_call(
        repair,
        'complete_umbrel_transaction',
        'repair_current_umbrel_runtime must complete only after re-verification',
    )
    if transaction_position > repair_verifier_position:
        runtime_contract_failure(
            'repair_current_umbrel_runtime must re-verify after the forced repair'
        )
    if transaction_position > safe_shutdown_position:
        runtime_contract_failure(
            'repair_current_umbrel_runtime must install safe shutdown after the forced repair transaction'
        )
    if safe_shutdown_position > repair_wait_position:
        runtime_contract_failure(
            'repair_current_umbrel_runtime must wait for system containers after safe-shutdown installation'
        )
    if repair_wait_position > repair_verifier_position:
        runtime_contract_failure(
            'repair_current_umbrel_runtime must wait for system containers before full re-verification'
        )
    repair_wait_failure, repair_wait_failure_position, _ = if_block(
        repair,
        r'![ \t]*wait_for_postcheck_system_containers',
        'current-version system-container convergence failure',
    )
    require_executable_call(
        repair_wait_failure,
        'fail_umbrel_transaction',
        'current-version system-container convergence failure must roll back through fail_umbrel_transaction',
    )
    if 'fail_umbrel_transaction "current-version system-container convergence did not complete within bounded readiness attempts."' not in repair_wait_failure:
        runtime_contract_failure(
            'current-version system-container convergence failure must use a generalized rollback message'
        )
    if not (safe_shutdown_position < repair_wait_failure_position < repair_verifier_position):
        runtime_contract_failure(
            'current-version system-container convergence failure must roll back before full re-verification'
        )
    if repair_verifier_position > completion_position:
        runtime_contract_failure(
            'repair_current_umbrel_runtime must complete after full re-verification'
        )
    if executable_call_positions(repair, 'finalize_install_state'):
        runtime_contract_failure(
            'repair_current_umbrel_runtime must not finalize before reconciliation re-verifies'
        )
    repair_call_positions = executable_call_positions(reconcile, 'repair_current_umbrel_runtime')
    if len(repair_call_positions) != 1:
        runtime_contract_failure(
            'reconciliation must contain exactly one bounded repair path'
        )
    repair_call_position = repair_call_positions[0]
    finalization_positions = executable_call_positions(reconcile, 'finalize_install_state')
    if not finalization_positions or finalization_positions[-1] < repair_call_position:
        runtime_contract_failure(
            'reconciliation must finalize only after the bounded repair re-verifies'
        )
    for label, body in (
        ('verify_umbrel_runtime_truth', verifier),
        ('finalize_install_state', finalize_body),
        ('report_umbrel_runtime_truth', report),
        ('repair_current_umbrel_runtime', repair),
        ('reconcile_current_version_runtime', reconcile),
    ):
        require_approved_commands(body, label, allowed_commands[label])

validate_runtime_truth_control_flow(text)

mutants = (
    (
        'missing-full-verifier-call',
        text.replace('  verify_umbrel_runtime_truth 1 || return 1\n', '', 1),
        'Runtime-truth control-flow contract failed: finalize_install_state must invoke full runtime truth verification',
    ),
    (
        'missing-configured-ref-resolution',
        text.replace(
            '  umbrel_image_ref_resolves_to_image_id "$runtime_image" "$expected_image_id" || {\n'
            '    report_umbrel_runtime_truth_failure "top-level-image-reference" "not-canonical" "Refusing to finalize because the live Umbrel runtime image reference could not be verified."\n'
            '    return 1\n'
            '  }\n',
            '',
            1,
        ),
        'Runtime-truth control-flow contract failed: runtime snapshot must prove the configured image ref resolves to the expected immutable ID',
    ),
    (
        'publication-before-verification',
        text.replace(
            '  verified_umbrel_runtime_snapshot || return 1\n'
            '  verify_umbrel_runtime_truth 1 || return 1\n'
            '  update_install_state finalized "" "$version" "" "$VERIFIED_UMBREL_RUNTIME_IMAGE" "$VERIFIED_UMBREL_RUNTIME_IMAGE_ID"\n',
            '  verified_umbrel_runtime_snapshot || return 1\n'
            '  update_install_state finalized "" "$version" "" "$VERIFIED_UMBREL_RUNTIME_IMAGE" "$VERIFIED_UMBREL_RUNTIME_IMAGE_ID"\n'
            '  verify_umbrel_runtime_truth 1 || return 1\n',
            1,
        ),
        'Runtime-truth control-flow contract failed: full runtime truth verification must precede final state publication',
    ),
    (
        'newer-version-repair-route',
        text.replace(
            '  echo "Installed version is newer than this updater target; no repair or state publication will run."\n'
            '  return 0\n',
            '  echo "Installed version is newer than this updater target; no repair or state publication will run."\n'
            '  repair_current_umbrel_runtime\n'
            '  return 0\n',
            1,
        ),
        'Runtime-truth control-flow contract failed: current>target route must not call mutator: repair_current_umbrel_runtime',
    ),
    (
        'check-only-mutator-route',
        text.replace(
            '  if [[ "$CHECK_ONLY" -eq 1 ]]; then\n'
            '    report_umbrel_runtime_truth\n'
            '    return\n'
            '  fi\n',
            '  if [[ "$CHECK_ONLY" -eq 1 ]]; then\n'
            '    repair_current_umbrel_runtime\n'
            '    return\n'
            '  fi\n',
            1,
        ),
        'Runtime-truth control-flow contract failed: CHECK_ONLY route must not call mutator: repair_current_umbrel_runtime',
    ),
    (
        'check-only-nested-inline-repair',
        text.replace(
            '  if [[ "$CHECK_ONLY" -eq 1 ]]; then\n'
            '    report_umbrel_runtime_truth\n'
            '    return\n'
            '  fi\n',
            '  if [[ "$CHECK_ONLY" -eq 1 ]]; then\n'
            '    report_umbrel_runtime_truth\n'
            '    if true; then repair_current_umbrel_runtime; fi\n'
            '    return\n'
            '  fi\n',
            1,
        ),
        'Runtime-truth control-flow contract failed: CHECK_ONLY route must not call mutator: repair_current_umbrel_runtime',
    ),
    (
        'newer-version-nested-inline-repair',
        text.replace(
            '  echo "Installed version is newer than this updater target; no repair or state publication will run."\n'
            '  return 0\n',
            '  echo "Installed version is newer than this updater target; no repair or state publication will run."\n'
            '  if true; then repair_current_umbrel_runtime; fi\n'
            '  return 0\n',
            1,
        ),
        'Runtime-truth control-flow contract failed: current>target route must not call mutator: repair_current_umbrel_runtime',
    ),
    (
        'second-inline-final-state-publication',
        text.replace(
            '  update_install_state finalized "" "$version" "" "$VERIFIED_UMBREL_RUNTIME_IMAGE" "$VERIFIED_UMBREL_RUNTIME_IMAGE_ID"\n',
            '  update_install_state finalized "" "$version" "" "$VERIFIED_UMBREL_RUNTIME_IMAGE" "$VERIFIED_UMBREL_RUNTIME_IMAGE_ID"; update_install_state finalized "" "$version" "" "$VERIFIED_UMBREL_RUNTIME_IMAGE" "$VERIFIED_UMBREL_RUNTIME_IMAGE_ID"\n',
            1,
        ),
        'Runtime-truth control-flow contract failed: finalize_install_state must contain exactly one final state publication',
    ),
    (
        'inline-transaction-before-identity',
        text.replace(
            '  if ! assert_fullnode_data_mount_safe >/dev/null 2>&1; then\n'
            '    err "Current-version runtime repair requires proven data identity and an existing top-level Umbrel container."\n'
            '    return 1\n'
            '  fi\n'
            '  if ! begin_umbrel_candidate_transaction 1; then\n',
            '  if ! begin_umbrel_candidate_transaction 1; then\n'
            '    return 1\n'
            '  fi; if ! assert_fullnode_data_mount_safe >/dev/null 2>&1; then\n'
            '    err "Current-version runtime repair requires proven data identity and an existing top-level Umbrel container."\n'
            '    return 1\n'
            '  fi\n'
            '  if false; then\n',
            1,
        ),
        'Runtime-truth control-flow contract failed: repair_current_umbrel_runtime must prove data identity before forced repair',
    ),
    (
        'completion-before-reverification',
        text.replace(
            '  if ! verify_umbrel_runtime_truth; then\n'
            '    fail_umbrel_transaction "current-version runtime repair did not converge"\n'
            '    return 1\n'
            '  fi\n'
            '  complete_umbrel_transaction\n',
            '  complete_umbrel_transaction\n'
            '  if ! verify_umbrel_runtime_truth; then\n'
            '    fail_umbrel_transaction "current-version runtime repair did not converge"\n'
            '    return 1\n'
            '  fi\n',
            1,
        ),
        'Runtime-truth control-flow contract failed: repair_current_umbrel_runtime must complete after full re-verification',
    ),
    (
        'missing-repair-system-convergence-wait',
        text.replace(
            '  if ! wait_for_postcheck_system_containers; then\n'
            '    err "Current-version system-container convergence did not complete within bounded readiness attempts."\n'
            '    fail_umbrel_transaction "current-version system-container convergence did not complete within bounded readiness attempts."\n'
            '    return 1\n'
            '  fi\n',
            '',
            1,
        ),
        'Runtime-truth control-flow contract failed: repair_current_umbrel_runtime must wait exactly once after safe-shutdown installation',
    ),
    (
        'repair-system-convergence-wait-after-full-verification',
        text.replace(
            '  if ! wait_for_postcheck_system_containers; then\n'
            '    err "Current-version system-container convergence did not complete within bounded readiness attempts."\n'
            '    fail_umbrel_transaction "current-version system-container convergence did not complete within bounded readiness attempts."\n'
            '    return 1\n'
            '  fi\n'
            '  if ! verify_umbrel_runtime_truth; then\n'
            '    fail_umbrel_transaction "current-version runtime repair did not converge"\n'
            '    return 1\n'
            '  fi\n',
            '  if ! verify_umbrel_runtime_truth; then\n'
            '    fail_umbrel_transaction "current-version runtime repair did not converge"\n'
            '    return 1\n'
            '  fi\n'
            '  if ! wait_for_postcheck_system_containers; then\n'
            '    err "Current-version system-container convergence did not complete within bounded readiness attempts."\n'
            '    fail_umbrel_transaction "current-version system-container convergence did not complete within bounded readiness attempts."\n'
            '    return 1\n'
            '  fi\n',
            1,
        ),
        'Runtime-truth control-flow contract failed: repair_current_umbrel_runtime must wait for system containers before full re-verification',
    ),
    (
        'extra-inline-bounded-repair',
        text.replace(
            '  repair_current_umbrel_runtime || return 1\n',
            '  repair_current_umbrel_runtime || return 1; repair_current_umbrel_runtime || return 1\n',
            1,
        ),
        'Runtime-truth control-flow contract failed: reconciliation must contain exactly one bounded repair path',
    ),
    (
        'finalization-before-bounded-repair',
        text.replace(
            '  repair_current_umbrel_runtime || return 1\n'
            '  finalize_install_state "$target_version"\n',
            '  finalize_install_state "$target_version"\n'
            '  repair_current_umbrel_runtime || return 1\n',
            1,
        ),
        'Runtime-truth control-flow contract failed: reconciliation must finalize only after the bounded repair re-verifies',
    ),
    (
        'quoted-fake-data-inspect',
        text.replace(
            '  data_source="$(inspect_umbrel_mount_source /data)"\n'
            '  expected_image_id="$(umbrel_image_id "$UMBREL_IMAGE")"\n'
            '  if ! candidate_umbrel_container_ready "$expected_image_id" "$data_source"; then\n',
            '  data_source="$(printf \'%s\' \'inspect_umbrel_mount_source /data\')"\n'
            '  expected_image_id="$(umbrel_image_id "$UMBREL_IMAGE")"\n'
            '  if ! candidate_umbrel_container_ready "$expected_image_id" "$data_source"; then\n',
            1,
        ),
        'Runtime-truth control-flow contract failed: full runtime verifier must compose executable predicate: inspect_umbrel_mount_source /data',
    ),
    (
        'commented-fake-data-inspect',
        text.replace(
            '  data_source="$(inspect_umbrel_mount_source /data)"\n'
            '  expected_image_id="$(umbrel_image_id "$UMBREL_IMAGE")"\n'
            '  if ! candidate_umbrel_container_ready "$expected_image_id" "$data_source"; then\n',
            '  data_source="$(printf \'%s\' unavailable)"\n'
            '  # inspect_umbrel_mount_source /data\n'
            '  expected_image_id="$(umbrel_image_id "$UMBREL_IMAGE")"\n'
            '  if ! candidate_umbrel_container_ready "$expected_image_id" "$data_source"; then\n',
            1,
        ),
        'Runtime-truth control-flow contract failed: full runtime verifier must compose executable predicate: inspect_umbrel_mount_source /data',
    ),
    (
        'report-eval-repair-dispatch',
        text.replace(
            '  if verify_umbrel_runtime_truth; then\n'
            '    info "Runtime truth diagnostic: predicate=all observed-state=canonical"\n'
            '    return 0\n',
            '  if verify_umbrel_runtime_truth; then\n'
            '    info "Runtime truth diagnostic: predicate=all observed-state=canonical"\n'
            '    eval repair_current_umbrel_runtime\n'
            '    return 0\n',
            1,
        ),
        'Runtime-truth control-flow contract failed: report_umbrel_runtime_truth must not use dynamic command dispatch: eval',
    ),
    (
        'report-variable-repair-dispatch',
        text.replace(
            '  if verify_umbrel_runtime_truth; then\n'
            '    info "Runtime truth diagnostic: predicate=all observed-state=canonical"\n'
            '    return 0\n',
            '  if verify_umbrel_runtime_truth; then\n'
            '    info "Runtime truth diagnostic: predicate=all observed-state=canonical"\n'
            '    fn=repair_current_umbrel_runtime\n'
            '    "$fn"\n'
            '    return 0\n',
            1,
        ),
        'Runtime-truth control-flow contract failed: report_umbrel_runtime_truth must not use dynamic command dispatch: variable invocation',
    ),
    (
        'report-shell-c-repair-dispatch',
        text.replace(
            '  if verify_umbrel_runtime_truth; then\n'
            '    info "Runtime truth diagnostic: predicate=all observed-state=canonical"\n'
            '    return 0\n',
            '  if verify_umbrel_runtime_truth; then\n'
            '    info "Runtime truth diagnostic: predicate=all observed-state=canonical"\n'
            '    bash -c \'repair_current_umbrel_runtime\'\n'
            '    return 0\n',
            1,
        ),
        'Runtime-truth control-flow contract failed: report_umbrel_runtime_truth must not use dynamic command dispatch: bash',
    ),
    (
        'report-timeout-shell-dispatch',
        text.replace(
            '  if verify_umbrel_runtime_truth; then\n'
            '    info "Runtime truth diagnostic: predicate=all observed-state=canonical"\n'
            '    return 0\n',
            '  if verify_umbrel_runtime_truth; then\n'
            '    info "Runtime truth diagnostic: predicate=all observed-state=canonical"\n'
            '    timeout bash -c \'repair_current_umbrel_runtime\'\n'
            '    return 0\n',
            1,
        ),
        'Runtime-truth control-flow contract failed: report_umbrel_runtime_truth must not invoke unapproved command: timeout',
    ),
    (
        'report-env-shell-dispatch',
        text.replace(
            '  if verify_umbrel_runtime_truth; then\n'
            '    info "Runtime truth diagnostic: predicate=all observed-state=canonical"\n'
            '    return 0\n',
            '  if verify_umbrel_runtime_truth; then\n'
            '    info "Runtime truth diagnostic: predicate=all observed-state=canonical"\n'
            '    env sh -c \'repair_current_umbrel_runtime\'\n'
            '    return 0\n',
            1,
        ),
        'Runtime-truth control-flow contract failed: report_umbrel_runtime_truth must not invoke unapproved command: env',
    ),
    (
        'report-python-shell-dispatch',
        text.replace(
            '  if verify_umbrel_runtime_truth; then\n'
            '    info "Runtime truth diagnostic: predicate=all observed-state=canonical"\n'
            '    return 0\n',
            '  if verify_umbrel_runtime_truth; then\n'
            '    info "Runtime truth diagnostic: predicate=all observed-state=canonical"\n'
            '    python3 -c \'repair_current_umbrel_runtime\'\n'
            '    return 0\n',
            1,
        ),
        'Runtime-truth control-flow contract failed: report_umbrel_runtime_truth must not invoke unapproved command: python3',
    ),
)
for name, mutant, expected_message in mutants:
    if mutant == text:
        runtime_contract_failure(f'negative mutant construction failed: {name}')
    try:
        validate_runtime_truth_control_flow(mutant)
    except SystemExit as failure:
        if str(failure) != expected_message:
            runtime_contract_failure(
                f'negative mutant {name} rejected for unexpected reason: {failure}'
            )
        print(f'  ok rejected {name}: {failure}')
    else:
        runtime_contract_failure(f'negative mutant was accepted: {name}')
print('  ok updater preserves data-mount gates, dry-run semantics, rollback truth, and all-target runtime-state invariants')
PY


printf '[verify] system package updater safety invariants\n'
python3 - <<'PY'
from pathlib import Path
text = Path('scripts/m1s-update-system-packages.sh').read_text(encoding='utf-8')
lifecycle = Path('scripts/m1s-docker-lifecycle.sh').read_text(encoding='utf-8')
for forbidden in ['mkfs.', 'sfdisk', 'parted', 'wipefs', 'sgdisk', 'gdisk', 'blkdiscard', 'shred']:
    if forbidden in text:
        raise SystemExit(f'System package updater must never contain destructive disk command: {forbidden}')
required = [
    'SCRIPT_VERSION="0.5.31"',
    '--dry-run',
    '--no-reboot',
    'STOP_TIMEOUT_SECONDS=300',
    'APT_LOCK_TIMEOUT_SECONDS=300',
    'apt_update_command',
    'm1s-docker-lifecycle.sh',
    'm1s_docker_lifecycle_load_running STOPPED_CONTAINERS',
    'Bitcoin-related containers are running and will be stopped gracefully',
    'm1s_docker_lifecycle_stop STOPPED_CONTAINERS "$STOP_TIMEOUT_SECONDS"',
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
    'is_umbrel_managed_container',
    'wait_for_umbrel_managed_containers',
    'docker start umbrel',
]
missing = [needle for needle in required if needle not in text]
if missing:
    print('Missing expected system package updater invariant text:')
    for needle in missing:
        print(f'  {needle}')
    raise SystemExit(1)
helper_required = [
    'docker ps --format',
    'run_cmd docker stop --timeout "$timeout_seconds"',
    'docker container inspect "$container"',
    'docker start "$container"',
]
helper_missing = [needle for needle in helper_required if needle not in lifecycle]
if helper_missing:
    print('Missing expected shared Docker lifecycle invariant text:')
    for needle in helper_missing:
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

printf '[verify] host residue detector invariants\n'
python3 - <<'PY'
from pathlib import Path
import re

text = Path('scripts/check-host-residue.sh').read_text(encoding='utf-8')


def section(start: str, end: str) -> str:
    start_position = text.find(start)
    end_position = text.find(end, start_position + len(start))
    if start_position == -1 or end_position == -1:
        raise SystemExit(f'Host residue detector contract section is missing: {start} ... {end}')
    return text[start_position:end_position]


manifest = section('EXPECTED="$(mktemp)"', 'expected_path()')
for required in [
    'grep -rhoE',
    "--include='*.sh'",
    "--exclude='check-host-residue.sh'",
    '"$REPO/scripts"',
    '> "$EXPECTED"',
]:
    if required not in manifest:
        raise SystemExit(f'Host residue manifest must be derived by grepping repository scripts: missing {required}')
for forbidden in ['EXPECTED_PATHS=(', 'cat > "$EXPECTED"', 'printf > "$EXPECTED"']:
    if forbidden in manifest:
        raise SystemExit(f'Host residue manifest must not become hand-maintained: found {forbidden}')

full_scan_derivation = section('derive_full_scan_dirs() {', 'expected_path()')
for required in [
    'while IFS= read -r manifest_path; do',
    'done < "$EXPECTED"',
    'parent_dir="${manifest_path%/*}"',
    'printf \'%s\\n\' "${EXPLICIT_HIGH_RISK_DIRS[@]}"',
    'is_broad_shared_dir "$candidate_dir"',
    'sort -u',
    'mapfile -t FULL_SCAN_DIRS < <(derive_full_scan_dirs)',
    'for host_dir in "${FULL_SCAN_DIRS[@]}"; do',
]:
    if required not in full_scan_derivation and required not in text:
        raise SystemExit(f'Host residue full-scan directories must be derived from the manifest: missing {required}')
for forbidden in ['WATCHED_DIRS=(', 'FULL_SCAN_DIRS=(']:
    if forbidden in text:
        raise SystemExit(f'Host residue full-scan directories must not become a bare hardcoded list: found {forbidden}')

retention_derivation = section(
    'RETENTION_HELPER="$REPO/scripts/m1s-backup-retention.sh"',
    'ORPHAN=0',
)
for required in [
    'derive_backup_retention_count() {',
    'M1S_BACKUP_RETENTION_COUNT',
    'sed -nE',
    '"$helper_path"',
    'BACKUP_RETENTION_BOUND="$(derive_backup_retention_count "$RETENTION_HELPER")"',
]:
    if required not in retention_derivation:
        raise SystemExit(f'Host residue backup bound must be derived from the retention helper: missing {required}')
hardcoded_retention_assignment = re.search(
    r'(?mi)^[ \t]*(?:readonly[ \t]+)?[A-Za-z_]*(?:RETENTION|BACKUP_(?:BOUND|LIMIT|COUNT))'
    r'[A-Za-z0-9_]*[ \t]*=[ \t]*["\']?[0-9]+["\']?[ \t]*$',
    text,
)
if hardcoded_retention_assignment:
    raise SystemExit(
        'Host residue backup bound must not be hardcoded: '
        + hardcoded_retention_assignment.group(0).strip()
    )

ours_classifier = section('is_ours() {', 'is_our_backup()')
substring_match = '[[ "$basename" == *m1s-* || "$basename" == *fullnode-* || "$basename" == *umbrel* ]]'
if substring_match not in ours_classifier:
    raise SystemExit('Host residue ownership classifier must use substring matching for NN-prefixed files')

gate_match = re.search(r'(?m)^GATE=\$\(\(([^)]*)\)\)$', text)
if not gate_match:
    raise SystemExit('Host residue gate expression is missing')
gate_terms = re.sub(r'\s+', '', gate_match.group(1)).split('+')
if gate_terms != ['ORPHAN', 'BACKUP', 'DRIFT', 'FAILCOUNT']:
    raise SystemExit(
        'Host residue gate must include only ours-orphan, ours-backup, settings-drift, and failed systemd units'
    )

print('  ok residue manifest, full-scan directories, and backup bound are derived; ownership and drift gate semantics are intact')
PY

printf '[verify] updater unit tests\n'
test_docker_guard_dir="$(mktemp -d)"
trap 'rm -rf "$test_docker_guard_dir"' EXIT
cat > "$test_docker_guard_dir/docker" <<'EOF'
#!/usr/bin/env bash
printf 'Unexpected real Docker invocation from test process: %s\n' "$*" >&2
exit 97
EOF
chmod +x "$test_docker_guard_dir/docker"
for test_script in "${test_scripts[@]}"; do
  PATH="$test_docker_guard_dir:$PATH" bash "$test_script"
  printf '  ok %s\n' "$test_script"
done

printf '[verify] workflow presence\n'
python3 - <<'PY'
from pathlib import Path
import re

pin_file = Path('.shellcheck-version')
if not pin_file.exists():
    raise SystemExit('.shellcheck-version is missing')
pin = pin_file.read_text(encoding='utf-8').strip()
if not re.fullmatch(r'\d+\.\d+\.\d+', pin):
    raise SystemExit(f'.shellcheck-version must be plain semver, got {pin!r}')

workflow = Path('.github/workflows/verify.yml')
if not workflow.exists():
    raise SystemExit('.github/workflows/verify.yml is missing')
text = workflow.read_text(encoding='utf-8')
required = [
    'actions/checkout@93cb6efe18208431cddfb8368fd83d5badbf9bfd',
    'shellcheck',
    'shellcheck_version="$(<.shellcheck-version)"',
    'releases/download/v${shellcheck_version}',
    'shellcheck-v${shellcheck_version}.linux.x86_64.tar.xz',
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
print(f'  ok GitHub workflow installs ShellCheck {pin} from the shared pin and runs the verifier')
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
    'real_device_validation_require_current_tree',
    'public_tree_require_no_ignored_paths',
    'source "$repo_root/scripts/public-tree-private-paths.sh"',
    'release notes expanded $(pwd) to this checkout path',
    r'safe\.directory="\$\(pwd\)"',
]
missing = [needle for needle in required if needle not in text]
if missing:
    print('Release gate is missing expected safety checks:')
    for needle in missing:
        print(f'  {needle}')
    raise SystemExit(1)
print('  ok release script gates tags/releases on clean tree, exact-tree real-device evidence, pushed HEAD, changelog, successful CI, and release-note scrub')
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
        'real_device_validation_require_current_tree',
        'public_tree_require_no_ignored_paths',
        'source "$repo_root/scripts/public-tree-private-paths.sh"',
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
    'scripts/public-tree-private-paths.sh': [
        'git check-ignore --no-index -q -- "$path"',
        'git ls-tree -r -z --name-only "$tree_hash"',
        'Refusing to publish: current tree contains paths matching .gitignore',
    ],
    'scripts/real-device-validation.sh': [
        "git worktree list --porcelain -z",
        "git rev-parse 'HEAD^{tree}'",
        'Missing real-device validation record for content tree:',
        'performed|not_applicable',
    ],
    'scripts/record-real-device-validation.sh': [
        'Missing required option:',
        'not_applicable',
        'EVIDENCE FOR',
        'HONEST CAVEAT',
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
