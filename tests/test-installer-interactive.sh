#!/usr/bin/env bash
set -Eeuo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

fail() {
  printf '[unit][FAIL] %s\n' "$1" >&2
  exit 1
}

pass() {
  printf '[unit][PASS] %s\n' "$1"
}

assert_eq() {
  local expected="$1"
  local actual="$2"
  local label="$3"
  [[ "$actual" == "$expected" ]] || fail "$label: expected '$expected', got '$actual'"
}

assert_contains() {
  local haystack="$1"
  local needle="$2"
  local label="$3"
  [[ "$haystack" == *"$needle"* ]] || fail "$label: missing '$needle'"
}

assert_not_contains() {
  local haystack="$1"
  local needle="$2"
  local label="$3"
  [[ "$haystack" != *"$needle"* ]] || fail "$label: unexpected '$needle'"
}

TEST_TMPDIR="$(mktemp -d)"
cleanup() {
  rm -rf "$TEST_TMPDIR"
}
trap cleanup EXIT

mkdir -p "$TEST_TMPDIR/bin"
cat > "$TEST_TMPDIR/bin/lsblk" <<'STUB'
#!/usr/bin/env bash
case "$*" in
  "-dn -o NAME,SIZE,TYPE,MODEL -P")
    printf '%s\n' 'NAME="mmcblk0" SIZE="32G" TYPE="disk" MODEL="eMMC"'
    printf '%s\n' 'NAME="nvme0n1" SIZE="2T" TYPE="disk" MODEL="NVME_A"'
    printf '%s\n' 'NAME="nvme1n1" SIZE="4T" TYPE="disk" MODEL="NVME_B"'
    printf '%s\n' 'NAME="sda" SIZE="500G" TYPE="disk" MODEL="USB_SSD"'
    ;;
  -nrpo\ MOUNTPOINT\ /dev/*)
    exit 0
    ;;
  -nrpo\ NAME,TYPE\ /dev/*)
    printf '%s disk\n' "$4"
    ;;
  -no\ PKNAME\ /dev/mmcblk0p2)
    printf 'mmcblk0\n'
    ;;
  -no\ PKNAME\ /dev/disk/by-uuid/root-mmc)
    exit 0
    ;;
  -dn\ -o\ TYPE\ /dev/mmcblk0)
    printf 'disk\n'
    ;;
  *)
    exit 0
    ;;
esac
STUB
chmod +x "$TEST_TMPDIR/bin/lsblk"
cat > "$TEST_TMPDIR/bin/readlink" <<'STUB'
#!/usr/bin/env bash
if [[ "$1" == "-f" ]]; then
  shift
  [[ "${1:-}" == "--" ]] && shift
  if [[ "${1:-}" == "/dev/disk/by-uuid/root-mmc" ]]; then
    printf '/dev/mmcblk0p2\n'
    exit 0
  fi
fi
/usr/bin/readlink "$@"
STUB
chmod +x "$TEST_TMPDIR/bin/readlink"
PATH="$TEST_TMPDIR/bin:$PATH"

# shellcheck source=scripts/m1s-clean-install-umbrel.sh
M1S_INSTALLER_LIB_ONLY=1 source scripts/m1s-clean-install-umbrel.sh

ROOT_DISK="mmcblk0"
TARGET_INPUT=""

printf '[unit] hostname policy stays aligned with umbrel.local\n'
installer_script="$(<scripts/m1s-clean-install-umbrel.sh)"
initial_setup_script="$(<scripts/m1s-initial-setup.sh)"
readme_ko="$(<README.md)"
readme_en="$(<README.en.md)"
assert_contains "$installer_script" "UMBREL_HOSTNAME=\"umbrel\"" "Fresh installer should force the host hostname to umbrel"
assert_contains "$initial_setup_script" "FIXED_HOSTNAME=\"umbrel\"" "Initial setup should keep hostname fixed to umbrel"
assert_contains "$initial_setup_script" "Keeps the hostname fixed to umbrel for http://umbrel.local access." "Initial setup help should document the fixed hostname policy"
assert_contains "$initial_setup_script" "Setting hostname to '\$FIXED_HOSTNAME' for umbrel.local access" "Initial setup should restore the fixed hostname if it drifted"
assert_contains "$initial_setup_script" "update_fixed_hostname_hosts \"\$current_hostname\" \"\$FIXED_HOSTNAME\"" "Initial setup should always normalize the 127.0.1.1 hosts entry"
assert_not_contains "$initial_setup_script" "New hostname [" "Initial setup must not prompt users to change the hostname"
assert_not_contains "$initial_setup_script" "INPUT_HOSTNAME" "Initial setup must not keep hostname input state"
assert_not_contains "$initial_setup_script" "NEW_HOSTNAME" "Initial setup must not keep a user-selectable hostname variable"
assert_not_contains "$initial_setup_script" "새 호스트 이름" "Initial setup must not keep the old Korean hostname prompt"
assert_contains "$readme_ko" "호스트 이름은 \`umbrel.local\` 접속을 위해 \`umbrel\`로 유지됩니다." "Korean README should document the fixed hostname policy"
assert_contains "$readme_en" "The hostname stays fixed to \`umbrel\` for \`umbrel.local\` access." "English README should document the fixed hostname policy"

printf '[unit] installer release interface baseline\n'
assert_contains "$readme_ko" 'sudo bash scripts/m1s-clean-install-umbrel.sh --release' "Korean guide must preserve the one-line release command"
assert_contains "$readme_en" 'sudo bash scripts/m1s-clean-install-umbrel.sh --release' "English guide must preserve the one-line release command"
assert_contains "$installer_script" '    --release)' "Installer must continue to accept --release"
assert_contains "$installer_script" 'PRESERVE_TAILSCALE=0' "Release mode must retain its existing tailscale behavior"
extract_fenced_blocks_with() {
  local file_path="$1"
  local needle="$2"

  python3 - "$file_path" "$needle" <<'PY'
import sys
from pathlib import Path

text = Path(sys.argv[1]).read_text()
needle = sys.argv[2]
blocks = []
parts = text.split('```')

for index in range(1, len(parts), 2):
    block = parts[index].strip('\n')
    if needle in block:
        blocks.append(block)

print('\n\n'.join(blocks))
PY
}

expected_release_block=$'bash\nsudo bash scripts/m1s-clean-install-umbrel.sh --release'
expected_update_block=$'bash\ncd /home/*/odroid-m1s-umbrel-recovery\nsudo git -c safe.directory="$(pwd)" fetch https://github.com/dongguri-jun/odroid-m1s-umbrel-recovery.git main\nsudo git -c safe.directory="$(pwd)" reset --hard FETCH_HEAD\nsudo bash scripts/m1s-update-umbrel.sh --check\nsudo bash scripts/m1s-update-umbrel.sh'
expected_two_update_blocks="$expected_update_block"$'\n\n'"$expected_update_block"

ko_release_block="$(extract_fenced_blocks_with README.md 'm1s-clean-install-umbrel.sh --release')"
en_release_block="$(extract_fenced_blocks_with README.en.md 'm1s-clean-install-umbrel.sh --release')"
assert_eq "$expected_release_block" "$ko_release_block" "Korean README should keep the exact one-line fresh-install command block"
assert_eq "$expected_release_block" "$en_release_block" "English README should keep the exact one-line fresh-install command block"

ko_update_blocks="$(extract_fenced_blocks_with README.md 'm1s-update-umbrel.sh --check')"
en_update_blocks="$(extract_fenced_blocks_with README.en.md 'm1s-update-umbrel.sh --check')"
assert_eq "$expected_two_update_blocks" "$ko_update_blocks" "Korean README should keep both exact five-line update command blocks"
assert_eq "$expected_two_update_blocks" "$en_update_blocks" "English README should keep both exact five-line update command blocks"
assert_eq "$ko_update_blocks" "$en_update_blocks" "Korean and English update command blocks should stay byte-identical"

assert_contains "$readme_ko" "서비스와 데이터 마이그레이션은 적용하지 않지만, 기본 official-origin auto-sync가 저장소 파일을 갱신할 수 있습니다." "Korean --check wording should reflect non-mutating but auto-sync-aware behavior"
assert_contains "$readme_en" "it does not apply any service or data migration, but the default official-origin auto-sync may refresh repository files." "English --check wording should reflect non-mutating but auto-sync-aware behavior"
assert_contains "$readme_ko" "Umbrel UI의 OS 업데이트 버튼은 이 Dockur 기반 설치 방식에서 지원되지 않습니다." "Korean Docker limitation copy should point users at the repository updater"
assert_contains "$readme_en" "The Umbrel UI OS update button is not supported in this Dockur-based installation." "English Docker limitation copy should point users at the repository updater"
pass "One-line --release interface baseline remains intact"

run_hosts_entry_case() {
  local case_name="$1"
  local current_hostname="$2"
  local initial_hosts="$3"
  local hosts_file="$TEST_TMPDIR/hosts-$case_name"
  printf '%s\n' "$initial_hosts" > "$hosts_file"
  (
    M1S_INITIAL_SETUP_LIB_ONLY=1
    HOSTS_FILE="$hosts_file"
    # shellcheck source=scripts/m1s-initial-setup.sh
    source scripts/m1s-initial-setup.sh
    DRY_RUN=0
    update_fixed_hostname_hosts "$current_hostname" umbrel
  )
  assert_contains "$(<"$hosts_file")" $'127.0.1.1\tumbrel' "Initial setup should normalize 127.0.1.1 for $case_name"
}

run_hosts_entry_case "already-umbrel-stale-hosts" "umbrel" $'127.0.0.1\tlocalhost\n127.0.1.1\toldname'
run_hosts_entry_case "drifted-hostname" "oldname" $'127.0.0.1\tlocalhost\n127.0.1.1\toldname'
run_hosts_entry_case "missing-1270011" "oldname" $'127.0.0.1\tlocalhost'
pass "Hostname stays fixed to the umbrel.local access path"

printf '[unit] installer device-level PCI remove + rescan dry-run\n'
DRY_RUN=1
set +e
device_rescan_output="$(nvme_pci_remove_rescan 2>&1)"
device_rescan_status=$?
set -e
assert_eq "0" "$device_rescan_status" "Device-level PCI remove + rescan helper should succeed in dry-run mode"
assert_contains "$device_rescan_output" "[DRY-RUN] echo 1 > /sys/bus/pci/devices/0000:01:00.0/remove" "Dry-run should show the PCI remove command"
assert_contains "$device_rescan_output" "[DRY-RUN] echo 1 > /sys/bus/pci/rescan" "Dry-run should show the PCI rescan command"
pass "Device-level PCI remove + rescan helper emits the expected dry-run commands"

printf '[unit] installer NVMe-only candidate filtering\n'
selection_output_file="$TEST_TMPDIR/selection-output.txt"
exec 3<<<$'1\n'
select_target_disk_interactive <&3 >"$selection_output_file" 2>&1
selection_status=$?
exec 3<&-
assert_eq "0" "$selection_status" "Selecting the first NVMe candidate should succeed"
assert_eq "/dev/nvme0n1" "$TARGET_INPUT" "First visible candidate should remain the first NVMe disk"
selection_output="$(<"$selection_output_file")"
assert_contains "$selection_output" "Detected non-root NVMe SSD storage disks:" "Selection list should describe NVMe-only candidates"
assert_not_contains "$selection_output" "/dev/sda" "Non-NVMe disks must not be shown in the candidate list"
pass "Only NVMe disks are shown as selectable candidates"

printf '[unit] installer interactive abort handling\n'
set +e
ctrl_c_output="$(printf '\003\n' | select_target_disk_interactive 2>&1)"
ctrl_c_status=$?
set -e
assert_eq "130" "$ctrl_c_status" "Ctrl-C control character should abort selection"
assert_contains "$ctrl_c_output" "Aborted by user." "Ctrl-C abort should explain why it exited"
assert_not_contains "$ctrl_c_output" "Invalid selection" "Ctrl-C must not be treated as a bad menu choice"
pass "Ctrl-C control character exits the NVMe selector"

set +e
quit_output="$(printf 'q\n' | select_target_disk_interactive 2>&1)"
quit_status=$?
set -e
assert_eq "130" "$quit_status" "q should abort selection"
assert_contains "$quit_output" "Aborted by user." "q abort should explain why it exited"
assert_not_contains "$quit_output" "Invalid selection" "q must not be treated as a bad menu choice"
pass "q exits the NVMe selector"

printf '[unit] installer explicit non-NVMe target guard\n'
set +e
non_nvme_guard_output="$(require_nvme_target_disk sda 2>&1)"
non_nvme_guard_status=$?
set -e
assert_eq "1" "$non_nvme_guard_status" "Non-NVMe explicit target should be rejected"
assert_contains "$non_nvme_guard_output" "currently supports NVMe SSD targets only" "Non-NVMe explicit target should explain the NVMe-only policy"
pass "Explicit non-NVMe targets are rejected"

printf '[unit] installer root disk safety gate\n'
assert_eq "mmcblk0" "$(detect_root_disk /dev/mmcblk0p2)" "Root partition path should resolve to eMMC parent disk"
assert_eq "mmcblk0" "$(detect_root_disk /dev/disk/by-uuid/root-mmc)" "Root symlink should resolve to eMMC parent disk"
set +e
unknown_root_output="$(require_emmc_root_disk '' 2>&1)"
unknown_root_status=$?
nvme_root_output="$(require_emmc_root_disk nvme0n1 2>&1)"
nvme_root_status=$?
set -e
assert_eq "1" "$unknown_root_status" "Unknown root disk should fail closed"
assert_contains "$unknown_root_output" "refusing to format any NVMe target" "Unknown root failure should explain fail-closed behavior"
assert_eq "1" "$nvme_root_status" "NVMe root disk should fail closed"
assert_contains "$nvme_root_output" "expects ODROID M1S to boot from eMMC" "NVMe root failure should explain eMMC-root policy"
ROOT_SOURCE="/dev/mmcblk0p2"
ROOT_DISK="mmcblk0"
TARGET_INPUT="/dev/nvme0n1"
TARGET_DISK="nvme0n1"
TARGET_PARTITION="/dev/nvme0n1p1"
assert_safe_root_target_layout
ROOT_DISK="nvme0n1"
set +e
unsafe_layout_output="$(assert_safe_root_target_layout 2>&1)"
unsafe_layout_status=$?
set -e
assert_eq "1" "$unsafe_layout_status" "NVMe-root layout should fail the final safety gate"
assert_contains "$unsafe_layout_output" "Refusing to format NVMe" "Unsafe layout failure should explain root/target risk"
ROOT_DISK="mmcblk0"
pass "Root disk safety gate fails closed unless eMMC-root and NVMe-target are proven"

printf '[unit] installer one-command NVMe recovery\n'
TARGET_INPUT=""
DRY_RUN=1
nvme_visible_state="missing"
resume_attempted_state=0
nvme_disk_visible() {
  [[ "$nvme_visible_state" == "visible" ]]
}
nvme_rescan_runtime() {
  nvme_visible_state="missing"
  return 0
}
nvme_pci_remove_rescan() {
  printf 'nvme_pci_remove_rescan\n'
  return 0
}
preinstall_resume_attempted() {
  [[ "$resume_attempted_state" -eq 1 ]]
}
apply_nvme_boot_mitigation() {
  printf 'apply_nvme_boot_mitigation\n'
}
write_preinstall_resume_state() {
  printf 'write_preinstall_resume_state\n'
}
install_preinstall_resume_unit() {
  printf 'install_preinstall_resume_unit\n'
}
clear_preinstall_resume_state() {
  printf 'clear_preinstall_resume_state\n'
}
set +e
one_command_recovery_output="$(maybe_recover_missing_nvme 2>&1)"
one_command_recovery_status=$?
set -e
assert_eq "0" "$one_command_recovery_status" "Missing NVMe without explicit target should enter automatic recovery dry-run path"
assert_contains "$one_command_recovery_output" "Attempting device-level PCI remove + rescan" "One-command flow should attempt device-level PCI recovery after a failed runtime rescan"
assert_contains "$one_command_recovery_output" "nvme_pci_remove_rescan" "One-command flow should call the device-level PCI remove + rescan helper"
assert_contains "$one_command_recovery_output" "Device-level PCI remove + rescan did not restore NVMe visibility. Applying boot-time NVMe mitigation and rebooting once." "One-command flow should promise automatic reboot recovery after the new PCI recovery step"
assert_contains "$one_command_recovery_output" "apply_nvme_boot_mitigation" "One-command flow should apply NVMe mitigation before reboot"
assert_contains "$one_command_recovery_output" "write_preinstall_resume_state" "One-command flow should persist resume state"
assert_contains "$one_command_recovery_output" "install_preinstall_resume_unit" "One-command flow should install the resume unit"
assert_contains "$one_command_recovery_output" "[DRY-RUN] systemctl reboot" "One-command flow should reboot automatically in dry-run"
assert_not_contains "$one_command_recovery_output" "explicit /dev/nvme0n1 target is supplied" "One-command flow must not require an explicit target anymore"
pass "Missing NVMe now triggers automatic one-command recovery without an explicit target"

printf '[unit] installer device-level PCI recovery short-circuit\n'
TARGET_INPUT=""
DRY_RUN=1
nvme_visible_state="missing"
resume_attempted_state=0
nvme_disk_visible() {
  [[ "$nvme_visible_state" == "visible" ]]
}
nvme_rescan_runtime() {
  nvme_visible_state="missing"
  return 0
}
nvme_pci_remove_rescan() {
  nvme_visible_state="visible"
  printf 'nvme_pci_remove_rescan_recovered\n'
  return 0
}
preinstall_resume_attempted() {
  [[ "$resume_attempted_state" -eq 1 ]]
}
set +e
short_circuit_recovery_output="$(maybe_recover_missing_nvme 2>&1)"
short_circuit_recovery_status=$?
set -e
assert_eq "0" "$short_circuit_recovery_status" "Device-level PCI remove + rescan should let the installer continue without reboot"
assert_contains "$short_circuit_recovery_output" "Recovered NVMe visibility via device-level PCI remove + rescan" "Short-circuit flow should report successful PCI remove + rescan recovery"
assert_not_contains "$short_circuit_recovery_output" "Applying boot-time NVMe mitigation" "Short-circuit flow should not escalate to boot-time mitigation"
pass "Device-level PCI remove + rescan can recover visibility before reboot"

printf '[unit] installer resume cleanup timing\n'
installer_text="$(<scripts/m1s-clean-install-umbrel.sh)"
assert_contains "$installer_text" 'TimeoutStartSec=infinity' 'Resume service should not time out during long post-reboot installs'
assert_contains "$installer_text" "if [[ \"\$AUTO_RESUME_INSTALL\" -ne 1 ]]; then" "Resume path should defer preinstall cleanup until after the resumed run"
assert_contains "$installer_text" 'clear_preinstall_resume_state

info "Done."' 'Resume artifacts should be cleared only after install state is written and the run completes'
pass "Resume service uses infinite timeout and deferred cleanup"

printf '[unit] installer waits for apt locks to clear\n'
DRY_RUN=0
APT_LOCK_FILES=("$TEST_TMPDIR/dpkg-lock-frontend")
: > "${APT_LOCK_FILES[0]}"
FUSER_CALLS_FILE="$TEST_TMPDIR/fuser-calls"
SLEEP_CALLS_FILE="$TEST_TMPDIR/sleep-calls"
printf '0\n' > "$FUSER_CALLS_FILE"
printf '0\n' > "$SLEEP_CALLS_FILE"
fuser() {
  local calls
  calls="$(<"$FUSER_CALLS_FILE")"
  calls=$((calls + 1))
  printf '%s\n' "$calls" > "$FUSER_CALLS_FILE"
  if [[ "$calls" -eq 1 ]]; then
    printf '3445\n'
  fi
}
sleep() {
  local calls
  calls="$(<"$SLEEP_CALLS_FILE")"
  calls=$((calls + 1))
  printf '%s\n' "$calls" > "$SLEEP_CALLS_FILE"
}
set +e
apt_lock_output="$(wait_for_apt_locks 2>&1)"
apt_lock_status=$?
set -e
assert_eq "0" "$apt_lock_status" "wait_for_apt_locks should continue once the lock holder is gone"
assert_eq "2" "$(<"$FUSER_CALLS_FILE")" "wait_for_apt_locks should re-check the lock after sleeping"
assert_eq "1" "$(<"$SLEEP_CALLS_FILE")" "wait_for_apt_locks should sleep while a lock holder is present"
assert_contains "$apt_lock_output" "Another process is holding apt/dpkg locks" "wait_for_apt_locks should explain the automatic wait"
pass "Installer waits for transient apt locks without user input"

printf '[unit] installer apt automation pause and restore\n'
APT_AUTOMATION_PAUSED=0
APT_AUTOMATION_RESTORE_UNITS=()
DRY_RUN=0
SYSTEMCTL_LOG="$TEST_TMPDIR/systemctl-apt-automation.log"
: > "$SYSTEMCTL_LOG"
systemd_unit_exists() {
  case "$1" in
    apt-daily.timer|apt-daily-upgrade.timer|apt-daily.service|apt-daily-upgrade.service|unattended-upgrades.service)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}
systemctl() {
  case "$1" in
    is-active)
      if [[ "$2" == "--quiet" ]]; then
        case "$3" in
          apt-daily.timer|apt-daily-upgrade.timer|unattended-upgrades.service)
            return 0
            ;;
          *)
            return 3
            ;;
        esac
      fi
      ;;
    stop|start)
      printf '%s %s\n' "$1" "$2" >> "$SYSTEMCTL_LOG"
      return 0
      ;;
  esac
  return 0
}
pause_apt_automation
assert_eq "1" "$APT_AUTOMATION_PAUSED" "pause_apt_automation should mark apt automation as paused"
assert_eq "apt-daily.timer apt-daily-upgrade.timer unattended-upgrades.service" "${APT_AUTOMATION_RESTORE_UNITS[*]}" "pause_apt_automation should remember only units active before pausing"
apt_pause_log="$(<"$SYSTEMCTL_LOG")"
assert_contains "$apt_pause_log" "stop apt-daily.timer" "pause_apt_automation should stop apt-daily.timer"
assert_contains "$apt_pause_log" "stop apt-daily-upgrade.timer" "pause_apt_automation should stop apt-daily-upgrade.timer"
assert_contains "$apt_pause_log" "stop unattended-upgrades.service" "pause_apt_automation should stop unattended-upgrades.service"
resume_apt_automation
apt_resume_log="$(<"$SYSTEMCTL_LOG")"
assert_contains "$apt_resume_log" "start apt-daily.timer" "resume_apt_automation should restore apt-daily.timer when it was previously active"
assert_contains "$apt_resume_log" "start apt-daily-upgrade.timer" "resume_apt_automation should restore apt-daily-upgrade.timer when it was previously active"
assert_contains "$apt_resume_log" "start unattended-upgrades.service" "resume_apt_automation should restore unattended-upgrades.service when it was previously active"
assert_not_contains "$apt_resume_log" "start apt-daily.service" "resume_apt_automation should not start inactive apt-daily.service"
assert_eq "0" "$APT_AUTOMATION_PAUSED" "resume_apt_automation should clear the paused marker"
: > "$SYSTEMCTL_LOG"
pause_apt_automation
set +e
false
cleanup_on_exit
cleanup_status=$?
set -e
cleanup_log="$(<"$SYSTEMCTL_LOG")"
assert_eq "1" "$cleanup_status" "cleanup_on_exit should preserve the failing command exit status"
assert_contains "$cleanup_log" "start apt-daily.timer" "cleanup_on_exit should restore apt automation after installer failure"
assert_contains "$cleanup_log" "start unattended-upgrades.service" "cleanup_on_exit should restore unattended-upgrades after installer failure"
installer_text="$(<scripts/m1s-clean-install-umbrel.sh)"
assert_contains "$installer_text" 'wait_for_apt_locks
pause_apt_automation
wait_for_apt_locks' 'Installer should wait, pause apt automation, then confirm locks are still clear before apt work'
assert_contains "$installer_text" 'wait_for_apt_locks
  apt-get -o DPkg::Lock::Timeout=300 update
  wait_for_apt_locks
  DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=300 install -y' 'Docker install should re-check apt locks between update and install'
pass "Installer pauses apt automation without adding user prompts and restores prior active units"

printf '[unit] installer single-NVMe auto-select\n'
TARGET_INPUT=""
set +e
autoselect_target_disk_if_single_candidate >/dev/null 2>&1
multiple_candidate_status=$?
set -e
assert_eq "1" "$multiple_candidate_status" "Multiple NVMe candidates should still require interactive selection"
assert_eq "" "$TARGET_INPUT" "Multiple NVMe candidates must not auto-select a target"

LSBLK_BACKUP="$TEST_TMPDIR/bin/lsblk.multiple"
cp "$TEST_TMPDIR/bin/lsblk" "$LSBLK_BACKUP"
cat > "$TEST_TMPDIR/bin/lsblk" <<'STUB'
#!/usr/bin/env bash
case "$*" in
  "-dn -o NAME,SIZE,TYPE,MODEL -P")
    printf '%s\n' 'NAME="mmcblk0" SIZE="32G" TYPE="disk" MODEL="eMMC"'
    printf '%s\n' 'NAME="nvme0n1" SIZE="2T" TYPE="disk" MODEL="NVME_A"'
    ;;
  -nrpo\ MOUNTPOINT\ /dev/*)
    exit 0
    ;;
  -nrpo\ NAME,TYPE\ /dev/*)
    printf '%s disk\n' "$4"
    ;;
  -no\ PKNAME\ /dev/mmcblk0p2)
    printf 'mmcblk0\n'
    ;;
  -no\ PKNAME\ /dev/disk/by-uuid/root-mmc)
    exit 0
    ;;
  -dn\ -o\ TYPE\ /dev/mmcblk0)
    printf 'disk\n'
    ;;
  *)
    exit 0
    ;;
esac
STUB
chmod +x "$TEST_TMPDIR/bin/lsblk"
TARGET_INPUT=""
single_candidate_output_file="$TEST_TMPDIR/single-candidate-output.txt"
set +e
autoselect_target_disk_if_single_candidate >"$single_candidate_output_file" 2>&1
single_candidate_status=$?
set -e
single_candidate_output="$(<"$single_candidate_output_file")"
mv "$LSBLK_BACKUP" "$TEST_TMPDIR/bin/lsblk"
chmod +x "$TEST_TMPDIR/bin/lsblk"
assert_eq "0" "$single_candidate_status" "Exactly one NVMe candidate should be auto-selected"
assert_eq "/dev/nvme0n1" "$TARGET_INPUT" "Single visible NVMe should be selected automatically"
assert_contains "$single_candidate_output" "Selecting it automatically" "Single-candidate auto-select should explain itself"
pass "Exactly one NVMe candidate is auto-selected for one-command installs"

printf '[unit] installer target-scoped SSD busy process cleanup\n'
TARGET_MOUNT_PATHS=("/mnt/fullnode" "/mnt/old-fullnode")
TARGET_EXISTING_PARTITIONS=("/dev/nvme0n1p1")
TARGET_DISK_PATH="/dev/nvme0n1"
TARGET_PARTITION="/dev/nvme0n1p1"
DATA_DIR="/mnt/fullnode"
DRY_RUN=0
SCRIPT_PATH_ABS="/tmp/m1s-clean-install-umbrel.sh"
FUSER_PHASE="initial"
KILL_LOG="$TEST_TMPDIR/kill.log"
: > "$KILL_LOG"

fuser() {
  case "$1" in
    /mnt/fullnode|/mnt/old-fullnode|/dev/nvme0n1p1)
      if [[ "$FUSER_PHASE" == "initial" ]]; then
        printf '1234 2222 1234 3333 4444\n'
      else
        printf '2222 3333 4444\n'
      fi
      ;;
    /dev/nvme0n1)
      if [[ "$FUSER_PHASE" == "initial" ]]; then
        printf '5555\n'
      fi
      ;;
  esac
}

ps() {
  local pid="" field=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -p)
        pid="$2"
        shift 2
        ;;
      -o)
        field="$2"
        shift 2
        ;;
      *)
        shift
        ;;
    esac
  done
  field="${field%=}"
  case "$field:$pid" in
    comm:1234) printf 'bitcoind\n' ;;
    args:1234) printf '/usr/local/bin/bitcoind -datadir=/mnt/fullnode/bitcoin\n' ;;
    ppid:1234) printf '1\n' ;;
    comm:2222) printf 'electrs\n' ;;
    args:2222) printf '/usr/bin/electrs --db-dir /mnt/fullnode/electrs\n' ;;
    ppid:2222) printf '1\n' ;;
    comm:3333) printf 'sshd\n' ;;
    args:3333) printf 'sshd: nordin@pts/0\n' ;;
    ppid:3333) printf '1\n' ;;
    comm:4444) printf 'bash\n' ;;
    args:4444) printf 'bash /tmp/m1s-clean-install-umbrel.sh --release\n' ;;
    ppid:4444) printf '1\n' ;;
    comm:5555) printf 'docker\n' ;;
    args:5555) printf 'docker compose --project-directory /data up -d\n' ;;
    ppid:5555) printf '1\n' ;;
    ppid:*) printf '0\n' ;;
  esac
}

kill() {
  printf '%s %s\n' "$1" "$2" >> "$KILL_LOG"
}

sleep() {
  if [[ "$1" == "3" ]]; then
    FUSER_PHASE="after_term"
  fi
}

busy_pids="$(collect_target_busy_pids | paste -sd ' ' -)"
assert_eq "1234 2222 3333 4444 5555" "$busy_pids" "Busy PID collection should deduplicate target-scoped holders and include raw-disk users"
killable_pids="$(filter_killable_target_pids 1234 2222 3333 4444 5555 2>/dev/null | paste -sd ' ' -)"
assert_eq "1234 2222 5555" "$killable_pids" "Protected SSH and installer PIDs should not be killable, but raw-disk docker holders should be"
stop_target_busy_processes >/dev/null 2>&1
kill_log="$(<"$KILL_LOG")"
assert_contains "$kill_log" "-TERM 1234" "First pass should send SIGTERM to the first killable SSD holder"
assert_contains "$kill_log" "-TERM 2222" "First pass should send SIGTERM to the second killable SSD holder"
assert_contains "$kill_log" "-TERM 5555" "First pass should send SIGTERM to raw-disk docker compose holders"
assert_not_contains "$kill_log" "-TERM 3333" "Protected sshd PID must not receive SIGTERM"
assert_not_contains "$kill_log" "-TERM 4444" "Installer PID must not receive SIGTERM"
assert_not_contains "$kill_log" "-KILL 1234" "PID gone after TERM must not receive SIGKILL"
assert_contains "$kill_log" "-KILL 2222" "Only the remaining killable SSD holder should receive SIGKILL"
pass "Target-scoped SSD busy cleanup uses TERM before scoped KILL, includes raw-disk holders, and preserves protected PIDs"

printf '[unit] installer raw-disk repartition re-check\n'
installer_text="$(<scripts/m1s-clean-install-umbrel.sh)"
assert_contains "$installer_text" 'Re-checking for stale SSD holders immediately before repartitioning the raw NVMe disk' 'Raw-disk repartition should re-check for stale SSD holders right before sfdisk'
assert_contains "$installer_text" 'stop_target_busy_processes
  if ! command -v sfdisk' 'Raw-disk repartition should run holder cleanup immediately before sfdisk'
pass "Raw-disk repartition path performs a final stale-holder cleanup before sfdisk"

printf '[unit] installer exact image and runtime-health success contract\n'
EXPECTED_UMBREL_IMAGE='dockurr/umbrel:1.7.4@sha256:e00c07a838ce3b50641a0a984abe155a7223abacab3426a55409edf21b6e0124'
DEFAULT_RESOLVED_UMBREL_IMAGE_ID='sha256:e00c07a838ce3b50641a0a984abe155a7223abacab3426a55409edf21b6e0124'
EXPECTED_TOR_PROXY_IMAGE='ghcr.io/getumbrel/tor:0.4.9.11'

assert_eq "$EXPECTED_UMBREL_IMAGE" "$IMAGE" "Installer must pin the exact Dockur Umbrel 1.7.4 arm64 image"
assert_not_contains "$installer_text" 'dockurr/umbrel:1.7.3' "Installer must not retain the old 1.7.3 product pin"
assert_contains "$installer_text" '  --image IMAGE' "Installer must continue to advertise the custom image override"
assert_contains "$installer_text" '    --image)' "Installer must continue to parse the custom image override"

assert_before() {
  local text="$1"
  local before="$2"
  local after="$3"
  local label="$4"
  local before_position after_position
  before_position="$(python3 -c 'import sys; print(sys.stdin.read().find(sys.argv[1]))' "$before" <<<"$text")"
  after_position="$(python3 -c 'import sys; print(sys.stdin.read().find(sys.argv[1]))' "$after" <<<"$text")"
  [[ "$before_position" -ge 0 && "$after_position" -ge 0 && "$before_position" -lt "$after_position" ]] || fail "$label"
}

printf '[unit] support policy precedes installer and setup mutations\n'
assert_contains "$installer_text" 'm1s-support-policy.sh' 'Installer must source the shared support policy'
assert_before "$installer_text" 'm1s_report_host_support' 'info "Stopping and removing Incus containers if present"' 'Installer must report unvalidated hosts before host-state mutation'
assert_contains "$initial_setup_script" 'm1s-support-policy.sh' 'Initial setup must source the shared support policy'
assert_before "$initial_setup_script" 'm1s_report_host_support' 'read -r -p "Enter new username: "' 'Initial setup must report unvalidated hosts before collecting mutation inputs'
pass 'installer and initial setup warnings precede mutation'

startup_phase="${installer_text#*info \"Pulling and starting Umbrel\"}"
assert_before "$startup_phase" 'pull_and_verify_umbrel_image' 'run_cmd docker run -d --name umbrel' "Installer must pull and verify the image before docker run"
assert_before "$startup_phase" 'install_umbrel_safe_shutdown' 'wait_for_umbrel_runtime_health' "Safe shutdown must be installed before the runtime-health gate"
assert_before "$startup_phase" 'wait_for_umbrel_runtime_health' 'info "Recording install state"' "Runtime health must pass before success state recording"

RUNTIME_DOCKER_LOG="$TEST_TMPDIR/runtime-docker.log"
: > "$RUNTIME_DOCKER_LOG"
FAKE_PULLED_IMAGE_ID="$DEFAULT_RESOLVED_UMBREL_IMAGE_ID"
FAKE_LIVE_IMAGE_ID="$DEFAULT_RESOLVED_UMBREL_IMAGE_ID"
FAKE_LIVE_IMAGE_REF="$IMAGE"
FAKE_PULLED_ARCHITECTURE='arm64'
FAKE_TOPLEVEL_STATE='running'
FAKE_LEGACY_AUTH_STATE='missing'
FAKE_LEGACY_TOR_STATE='missing'
FAKE_CANONICAL_AUTH_STATE='running'
FAKE_CANONICAL_TOR_STATE='running'
FAKE_CANONICAL_TOR_IMAGE="$EXPECTED_TOR_PROXY_IMAGE@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
FAKE_SHUTDOWN_HEALTH=0
FAKE_HTTP_HEALTH=0

docker() {
  local format='' container="${!#}" arg
  printf 'docker' >> "$RUNTIME_DOCKER_LOG"
  for arg in "$@"; do
    printf ' %q' "$arg" >> "$RUNTIME_DOCKER_LOG"
    [[ "$arg" == --format=* ]] && format="${arg#--format=}"
  done
  printf '\n' >> "$RUNTIME_DOCKER_LOG"

  case "$1" in
    pull)
      return 0
      ;;
    image)
      [[ "${2:-}" == 'inspect' ]] || return 1
      case "$format" in
        '{{.Id}}') printf '%s\n' "$FAKE_PULLED_IMAGE_ID" ;;
        '{{.Architecture}}') printf '%s\n' "$FAKE_PULLED_ARCHITECTURE" ;;
      esac
      ;;
    inspect)
      case "$format" in
        *'.State.Status'*)
          case "$container" in
            umbrel) printf '%s\n' "$FAKE_TOPLEVEL_STATE" ;;
            auth) printf '%s\n' "$FAKE_LEGACY_AUTH_STATE" ;;
            tor_proxy) printf '%s\n' "$FAKE_LEGACY_TOR_STATE" ;;
            umbrel_auth) printf '%s\n' "$FAKE_CANONICAL_AUTH_STATE" ;;
            umbrel_tor_proxy) printf '%s\n' "$FAKE_CANONICAL_TOR_STATE" ;;
          esac
          ;;
        *'.Config.Image'*)
          case "$container" in
            umbrel) printf '%s\n' "$FAKE_LIVE_IMAGE_REF" ;;
            tor_proxy) printf '%s\n' "$EXPECTED_TOR_PROXY_IMAGE" ;;
            umbrel_tor_proxy) printf '%s\n' "$FAKE_CANONICAL_TOR_IMAGE" ;;
          esac
          ;;
        *'.HostConfig.RestartPolicy.Name'*)
          printf 'always\n'
          ;;
        *'.Destination "/data"'*)
          printf '%s\n' "$HOST_DATA_ALIAS"
          ;;
        *'.Destination "/var/run/docker.sock"'*)
          printf '/var/run/docker.sock\n'
          ;;
        *'.Image'*)
          printf '%s\n' "$FAKE_LIVE_IMAGE_ID"
          ;;
      esac
      ;;
    exec)
      return "$FAKE_SHUTDOWN_HEALTH"
      ;;
  esac
}

curl() {
  {
    printf 'curl'
    printf ' %q' "$@"
    printf '\n'
  } >> "$RUNTIME_DOCKER_LOG"
  return "$FAKE_HTTP_HEALTH"
}

get_exact_data_mount_source() {
  printf '%s\n' "$TARGET_PARTITION"
}

sleep() {
  printf 'sleep %q\n' "$1" >> "$RUNTIME_DOCKER_LOG"
}

DRY_RUN=0
DATA_DIR='/mnt/fullnode'
HOST_DATA_ALIAS='/data'
TARGET_PARTITION='/dev/nvme0n1p1'
INSTALL_STATE_DIR="$TEST_TMPDIR/runtime-state"
INSTALL_STATE_FILE="$INSTALL_STATE_DIR/installed.json"
UMBREL_RUNTIME_HEALTH_ATTEMPTS=2
UMBREL_RUNTIME_HEALTH_DELAY=0

pull_and_verify_umbrel_image
runtime_log="$(<"$RUNTIME_DOCKER_LOG")"
assert_before "$runtime_log" "docker pull $EXPECTED_UMBREL_IMAGE" "docker image inspect" "Runtime must inspect the pulled image after pulling it"
assert_eq "$DEFAULT_RESOLVED_UMBREL_IMAGE_ID" "$RESOLVED_UMBREL_IMAGE_ID" "Exact pinned default must retain Docker's resolved local image ID"
assert_not_contains "$installer_text" 'EXPECTED_UMBREL_IMAGE_ID=' "Installer must not hard-code a Docker-local image ID for the default exact digest"

if ! umbrel_runtime_health_once; then
  fail "Dockur 1.7.4 canonical umbrel_auth and umbrel_tor_proxy with a valid pinned Tor digest must satisfy installer runtime health"
fi

if ! is_expected_tor_proxy_image "$EXPECTED_TOR_PROXY_IMAGE"; then
  fail "installer must accept the tag-only Tor image contract"
fi
if ! is_expected_tor_proxy_image "$FAKE_CANONICAL_TOR_IMAGE"; then
  fail "installer must accept the exact tag with a valid 64-character lowercase digest"
fi
for invalid_tor_image in \
  "ghcr.io/other/tor:0.4.9.11" \
  "ghcr.io/getumbrel/tor:0.4.9.10" \
  "ghcr.io/getumbrel/tor:0.4.9.11@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" \
  "ghcr.io/getumbrel/tor:0.4.9.11@sha256:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA" \
  "ghcr.io/getumbrel/tor:0.4.9.11@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa:extra"; do
  if is_expected_tor_proxy_image "$invalid_tor_image"; then
    fail "installer Tor image contract must reject $invalid_tor_image"
  fi
done

wait_for_umbrel_runtime_health
runtime_log="$(<"$RUNTIME_DOCKER_LOG")"
assert_contains "$runtime_log" '.Image' "Runtime health must inspect the live top-level image ID"
assert_contains "$runtime_log" '.Config.Image' "Runtime health must inspect live image references"
assert_contains "$runtime_log" '.HostConfig.RestartPolicy.Name' "Runtime health must require the always restart policy"
assert_contains "$installer_text" 'eq .Destination "/data"' "Runtime health must inspect the /data mount"
assert_contains "$installer_text" 'eq .Destination "/var/run/docker.sock"' "Runtime health must inspect the Docker socket mount"
assert_contains "$runtime_log" 'docker inspect --format=\{\{.State.Status\}\} umbrel_auth' "Runtime health must require a running canonical auth container"
assert_contains "$runtime_log" 'docker inspect --format=\{\{.State.Status\}\} umbrel_tor_proxy' "Runtime health must require a running canonical Tor container"
assert_contains "$installer_text" "EXPECTED_TOR_PROXY_IMAGE=\"$EXPECTED_TOR_PROXY_IMAGE\"" "Runtime health must require Tor 0.4.9.11"
assert_contains "$runtime_log" 'docker exec umbrel grep -q docker\ update' "Runtime health must verify the safe-shutdown source patch"
assert_contains "$runtime_log" 'curl -fsS --max-time' "Runtime health must require local HTTP"

printf '[unit] installer writes content-hashed 75s shutdown UI asset\n'
(
FAKE_UI_ROOT="$TEST_TMPDIR/umbreld-ui"
FAKE_UI_ASSET_DIR="$FAKE_UI_ROOT/assets"
mkdir -p "$FAKE_UI_ASSET_DIR"
source_callback='he==="shutting-down"&&!v&&(ce.isError||ce.failureCount>0)&&(b(!0),setTimeout(()=>S(!0),30*Kh))'
public_callback='he==="shutting-down"&&!v&&(b(!0),setTimeout(()=>S(!0),30*Kh))'
canonical_callback='he==="shutting-down"&&!v&&(b(!0),setTimeout(()=>S(!0),75*Kh))'
# shellcheck disable=SC2016 # Literal React Compiler minified variable names.
memo_prefix='let $e;e[56]!==v||e[57]!==he||e[58]!==ce.failureCount||e[59]!==ce.isError?($e=()=>{'
# shellcheck disable=SC2016 # Literal React Compiler minified variable names.
memo_suffix='},e[56]=v,e[57]=he,e[58]=ce.failureCount,e[59]=ce.isError,e[60]=$e):$e=e[60];let We;e[61]!==v||e[62]!==he||e[63]!==ce.failureCount||e[64]!==ce.isError||e[65]!==a?(We=[v,he,ce.failureCount,ce.isError,a],e[61]=v,e[62]=he,e[63]=ce.failureCount,e[64]=ce.isError,e[65]=a,e[66]=We):We=e[66],C.useEffect($e,We)'
source_region="${memo_prefix}${source_callback}${memo_suffix}"
public_region="${memo_prefix}${public_callback}${memo_suffix}"
canonical_region="${memo_prefix}${canonical_callback}${memo_suffix}"

docker() {
  if [[ "$1" == "exec" ]]; then
    shift
    [[ "${1:-}" == "-i" ]] && shift
    [[ "${1:-}" == "umbrel" ]] || return 1
    shift
    M1S_TEST_UMBREL_UI_ROOT="$FAKE_UI_ROOT" "$@"
    return $?
  fi
  return 1
}

reset_shutdown_ui_fixture() {
  rm -rf "$FAKE_UI_ROOT"
  mkdir -p "$FAKE_UI_ASSET_DIR"
}

write_shutdown_index() {
  printf '<script type="module" crossorigin src="%s"></script>\n' "$1" > "$FAKE_UI_ROOT/index.html"
}

write_vite_modulepreload_shutdown_index() {
  cp tests/fixtures/shutdown-ui-cache/vite-modulepreload-six-js-refs.html "$FAKE_UI_ROOT/index.html"
}

write_vite_shared_entry_modulepreload_shutdown_index() {
  cp tests/fixtures/shutdown-ui-cache/vite-modulepreload-shared-entry-six-js-refs.html "$FAKE_UI_ROOT/index.html"
}

write_vite_split_chunk_shutdown_fixture() {
  cp -R tests/fixtures/shutdown-ui-cache/vite-split-chunk/. "$FAKE_UI_ROOT/"
}

hashed_shutdown_name_for() {
  python3 - "$1" "$2" <<'PY'
import hashlib
import sys
from pathlib import Path

path = Path(sys.argv[1])
stem = sys.argv[2]
digest = hashlib.sha256(path.read_bytes()).hexdigest()[:12]
print(f"{stem}.m1s-{digest}.js")
PY
}

assert_hashed_shutdown_patch() {
  local label="$1"
  local region="$2"
  reset_shutdown_ui_fixture
  local old_asset="$FAKE_UI_ASSET_DIR/index-7c0be990.js"
  printf 'before;%s;after\n' "$region" > "$old_asset"
  write_shutdown_index '/assets/index-7c0be990.js'
  local old_asset_before old_index_before
  old_asset_before="$(<"$old_asset")"
  old_index_before="$(<"$FAKE_UI_ROOT/index.html")"
  if verify_umbrel_shutdown_ui >/dev/null 2>&1; then
    fail "$label verify must reject a non-canonical shutdown UI before patching"
  fi
  patch_umbrel_shutdown_ui
  verify_umbrel_shutdown_ui
  assert_eq "$old_asset_before" "$(<"$old_asset")" "$label old immutable asset bytes must remain unchanged"
  [[ "$old_index_before" != "$(<"$FAKE_UI_ROOT/index.html")" ]] || fail "$label index must be rewritten to a new hashed URL"
  local new_asset_name new_asset_path expected_name index_text patched_asset
  new_asset_name="$(basename "$(compgen -G "$FAKE_UI_ASSET_DIR/index-7c0be990.m1s-*.js")")"
  new_asset_path="$FAKE_UI_ASSET_DIR/$new_asset_name"
  expected_name="$(hashed_shutdown_name_for "$new_asset_path" 'index-7c0be990')"
  assert_eq "$expected_name" "$new_asset_name" "$label filename must contain the canonical content hash"
  patched_asset="$(<"$new_asset_path")"
  index_text="$(<"$FAKE_UI_ROOT/index.html")"
  assert_contains "$patched_asset" "$canonical_region" "$label patched asset should use the 75s status-only branch"
  assert_contains "$patched_asset" "$memo_suffix" "$label patched asset should preserve the React Compiler dependency array"
  assert_not_contains "$patched_asset" "$source_callback" "$label patched asset should remove the upstream error gate"
  assert_not_contains "$patched_asset" "$public_callback" "$label patched asset should remove the 30s status-only branch"
  assert_contains "$index_text" "/assets/$new_asset_name" "$label index must reference the new hashed asset"
  patch_umbrel_shutdown_ui
  assert_eq "$patched_asset" "$(<"$new_asset_path")" "$label canonical rerun must leave hashed asset bytes unchanged"
  assert_eq "$index_text" "$(<"$FAKE_UI_ROOT/index.html")" "$label canonical rerun must leave index unchanged"
}

assert_patch_fails_without_index_mutation() {
  local label="$1"
  local before_index=""
  [[ -f "$FAKE_UI_ROOT/index.html" ]] && before_index="$(<"$FAKE_UI_ROOT/index.html")"
  if patch_umbrel_shutdown_ui >/dev/null 2>&1; then
    fail "$label should fail closed"
  fi
  local after_index=""
  [[ -f "$FAKE_UI_ROOT/index.html" ]] && after_index="$(<"$FAKE_UI_ROOT/index.html")"
  assert_eq "$before_index" "$after_index" "$label must not mutate index.html"
}

assert_hashed_shutdown_patch 'upstream error-gated 30s branch' "$source_region"
assert_hashed_shutdown_patch 'public v0.5.28 status-only 30s branch' "$public_region"

assert_vite_modulepreload_shutdown_patch() {
  reset_shutdown_ui_fixture
  local old_asset="$FAKE_UI_ASSET_DIR/entry-module.js"
  printf 'before;%s;after\n' "$source_region" > "$old_asset"
  write_vite_modulepreload_shutdown_index
  local old_asset_before old_index_before
  old_asset_before="$(<"$old_asset")"
  old_index_before="$(<"$FAKE_UI_ROOT/index.html")"
  patch_umbrel_shutdown_ui
  verify_umbrel_shutdown_ui
  assert_eq "$old_asset_before" "$(<"$old_asset")" "Vite modulepreload fixture must preserve the old immutable asset"
  [[ "$old_index_before" != "$(<"$FAKE_UI_ROOT/index.html")" ]] || fail "Vite modulepreload fixture must rewrite index.html"
  local new_asset_name new_asset_path expected_name index_text patched_asset
  new_asset_name="$(basename "$(compgen -G "$FAKE_UI_ASSET_DIR/entry-module.m1s-*.js")")"
  new_asset_path="$FAKE_UI_ASSET_DIR/$new_asset_name"
  expected_name="$(hashed_shutdown_name_for "$new_asset_path" 'entry-module')"
  assert_eq "$expected_name" "$new_asset_name" "Vite modulepreload fixture filename must contain the content hash"
  patched_asset="$(<"$new_asset_path")"
  index_text="$(<"$FAKE_UI_ROOT/index.html")"
  assert_contains "$patched_asset" "$canonical_region" "Vite modulepreload fixture must patch the executable module entry"
  assert_contains "$index_text" 'href="/assets/chunk-alpha.js"' "Vite modulepreload fixture must preserve modulepreload hints"
  assert_contains "$index_text" "/assets/$new_asset_name" "Vite modulepreload fixture must retarget only the executable module entry"
  assert_not_contains "$index_text" 'src="/assets/entry-module.js"' "Vite modulepreload fixture must remove the old executable module entry reference"
  assert_contains "$index_text" "{\"imports\":{\"/assets/entry-module.js\":\"/assets/$new_asset_name\"}}" "Vite modulepreload fixture must map old dependent imports to the generated entry"
  patch_umbrel_shutdown_ui
  assert_eq "$patched_asset" "$(<"$new_asset_path")" "Vite modulepreload fixture rerun must leave the generated asset unchanged"
  assert_eq "$index_text" "$(<"$FAKE_UI_ROOT/index.html")" "Vite modulepreload fixture rerun must leave index.html unchanged"
}

assert_vite_modulepreload_shutdown_patch

assert_vite_shared_entry_modulepreload_shutdown_patch() {
  reset_shutdown_ui_fixture
  local old_asset="$FAKE_UI_ASSET_DIR/entry-module.js"
  printf 'before;%s;after\n' "$source_region" > "$old_asset"
  write_vite_shared_entry_modulepreload_shutdown_index
  patch_umbrel_shutdown_ui
  verify_umbrel_shutdown_ui
  local new_asset_name index_text
  new_asset_name="$(basename "$(compgen -G "$FAKE_UI_ASSET_DIR/entry-module.m1s-*.js")")"
  index_text="$(<"$FAKE_UI_ROOT/index.html")"
  assert_contains "$index_text" 'href="/assets/entry-module.js"' "Shared-entry modulepreload hint must remain unchanged"
  assert_contains "$index_text" "src=\"/assets/$new_asset_name\"" "Shared-entry executable script must point to the generated asset"
  assert_not_contains "$index_text" 'src="/assets/entry-module.js"' "Shared-entry executable script must not retain the old asset"
}

assert_vite_shared_entry_modulepreload_shutdown_patch

assert_late_preloaded_map_fails_closed() {
  reset_shutdown_ui_fixture
  write_vite_split_chunk_shutdown_fixture
  printf 'before;%s;after\n' "$source_region" > "$FAKE_UI_ASSET_DIR/old-entry.js"
  patch_umbrel_shutdown_ui
  local generated_name before_index after_index patch_exit verify_exit
  generated_name="$(basename "$(compgen -G "$FAKE_UI_ASSET_DIR/old-entry.m1s-*.js")")"
  printf '<link rel="modulepreload" href="/assets/dependent.js">\n<script type="importmap" data-m1s-shutdown-ui>{"imports":{"/assets/old-entry.js":"/assets/%s"}}</script>\n<script type="module" src="/assets/%s"></script>\n' "$generated_name" "$generated_name" > "$FAKE_UI_ROOT/index.html"
  before_index="$(<"$FAKE_UI_ROOT/index.html")"
  if patch_umbrel_shutdown_ui >/dev/null 2>&1; then patch_exit=0; else patch_exit=$?; fi
  if verify_umbrel_shutdown_ui >/dev/null 2>&1; then verify_exit=0; else verify_exit=$?; fi
  after_index="$(<"$FAKE_UI_ROOT/index.html")"
  [[ "$patch_exit" -ne 0 && "$verify_exit" -ne 0 ]] || fail "late preloaded managed map must be rejected by patch and verification: patch_exit=$patch_exit verify_exit=$verify_exit"
  assert_eq "$before_index" "$after_index" 'late preloaded managed map must not mutate index.html'
}

assert_late_preloaded_map_fails_closed

assert_vite_split_chunk_import_map_patch() {
  reset_shutdown_ui_fixture
  write_vite_split_chunk_shutdown_fixture
  local old_asset="$FAKE_UI_ASSET_DIR/old-entry.js"
  printf 'before;%s;after\nimport("./settings-content.js")\n' "$source_region" > "$old_asset"
  local old_asset_before
  old_asset_before="$(<"$old_asset")"
  patch_umbrel_shutdown_ui
  local new_asset_name index_text expected_map managed_map_offset modulepreload_offset module_script_offset
  new_asset_name="$(basename "$(compgen -G "$FAKE_UI_ASSET_DIR/old-entry.m1s-*.js")")"
  index_text="$(<"$FAKE_UI_ROOT/index.html")"
  expected_map="{\"imports\":{\"/assets/old-entry.js\":\"/assets/$new_asset_name\"}}"
  assert_eq "$old_asset_before" "$(<"$old_asset")" "Split-chunk fixture must preserve the immutable original entry"
  assert_contains "$index_text" "$expected_map" "Split-chunk fixture must map the dependent old-entry import to the generated entry"
  assert_contains "$index_text" 'data-m1s-shutdown-ui' "Split-chunk fixture must install one managed import map"
  [[ "$(grep -o 'data-m1s-shutdown-ui' <<<"$index_text" | wc -l)" -eq 1 ]] || fail "Split-chunk fixture must install exactly one managed import map"
  managed_map_offset="$(python3 -c 'import sys; print(sys.stdin.read().find("data-m1s-shutdown-ui"))' <<<"$index_text")"
  modulepreload_offset="$(python3 -c 'import sys; print(sys.stdin.read().find("rel=\"modulepreload\""))' <<<"$index_text")"
  module_script_offset="$(python3 -c 'import sys; print(sys.stdin.read().find("<script type=\"module\""))' <<<"$index_text")"
  [[ "$managed_map_offset" -ge 0 && "$managed_map_offset" -lt "$modulepreload_offset" && "$managed_map_offset" -lt "$module_script_offset" ]] || fail "Split-chunk fixture must insert the import map before modulepreload and module execution"
  [[ "${index_text%%<script type=\"module\"*}" == *'data-m1s-shutdown-ui'* ]] || fail "Split-chunk fixture must insert the import map before module execution"
  assert_contains "$(<"$FAKE_UI_ASSET_DIR/dependent.js")" 'import "./old-entry.js"' "Split-chunk fixture must retain the preloaded dependent static original import"
  assert_contains "$(<"$FAKE_UI_ASSET_DIR/settings-content.js")" 'import "./old-entry.js"' "Split-chunk fixture must retain the dependent Vite static old-entry import"
  verify_umbrel_shutdown_ui
}

assert_vite_split_chunk_import_map_patch

reset_shutdown_ui_fixture
canonical_asset="$FAKE_UI_ASSET_DIR/index-7c0be990.js"
printf 'before;%s;after\n' "$canonical_region" > "$canonical_asset"
canonical_name="$(hashed_shutdown_name_for "$canonical_asset" 'index-7c0be990')"
cp "$canonical_asset" "$FAKE_UI_ASSET_DIR/$canonical_name"
write_shutdown_index "/assets/$canonical_name"
canonical_index_before="$(<"$FAKE_UI_ROOT/index.html")"
canonical_asset_before="$(<"$FAKE_UI_ASSET_DIR/$canonical_name")"
patch_umbrel_shutdown_ui
verify_umbrel_shutdown_ui
[[ "$canonical_index_before" != "$(<"$FAKE_UI_ROOT/index.html")" ]] || fail "canonical hashed shutdown UI without a managed map must be repaired"
assert_eq "$canonical_asset_before" "$(<"$FAKE_UI_ASSET_DIR/$canonical_name")" "canonical hashed shutdown UI rerun should be byte-idempotent"
canonical_index_after_repair="$(<"$FAKE_UI_ROOT/index.html")"
assert_contains "$canonical_index_after_repair" "{\"imports\":{\"/assets/index-7c0be990.js\":\"/assets/$canonical_name\"}}" "canonical repair must map the immutable original entry"
patch_umbrel_shutdown_ui
assert_eq "$canonical_index_after_repair" "$(<"$FAKE_UI_ROOT/index.html")" "canonical managed-map rerun should be byte-idempotent"

assert_bad_managed_import_map_fails_closed() {
  local label="$1"
  local mode="$2"
  reset_shutdown_ui_fixture
  printf 'before;%s;after\n' "$source_region" > "$FAKE_UI_ASSET_DIR/index-7c0be990.js"
  write_shutdown_index '/assets/index-7c0be990.js'
  patch_umbrel_shutdown_ui
  local generated_name managed_map maps
  generated_name="$(basename "$(compgen -G "$FAKE_UI_ASSET_DIR/index-7c0be990.m1s-*.js")")"
  managed_map="<script type=\"importmap\" data-m1s-shutdown-ui>{\"imports\":{\"/assets/index-7c0be990.js\":\"/assets/$generated_name\"}}</script>"
  case "$mode" in
    malformed) maps='<script type="importmap" data-m1s-shutdown-ui>{not-json}</script>' ;;
    duplicate) maps="$managed_map$managed_map" ;;
    wrong-target) maps='<script type="importmap" data-m1s-shutdown-ui>{"imports":{"/assets/index-7c0be990.js":"/assets/wrong.m1s-000000000000.js"}}</script>' ;;
    unsafe-target) maps='<script type="importmap" data-m1s-shutdown-ui>{"imports":{"/assets/index-7c0be990.js":"/assets/index-7c0be990.m1s-000000000000.js?unsafe"}}</script>' ;;
    unsafe-fragment) maps='<script type="importmap" data-m1s-shutdown-ui>{"imports":{"/assets/index-7c0be990.js":"/assets/index-7c0be990.m1s-000000000000.js#unsafe"}}</script>' ;;
    conflicting-unmanaged) maps="<script type=\"importmap\">{\"imports\":{\"/assets/index-7c0be990.js\":\"/assets/conflict.js\"}}</script>$managed_map" ;;
    *) fail "unknown managed import map test mode: $mode" ;;
  esac
  printf '%s\n<script type="module" src="/assets/%s"></script>\n' "$maps" "$generated_name" > "$FAKE_UI_ROOT/index.html"
  assert_patch_fails_without_index_mutation "$label"
  if verify_umbrel_shutdown_ui >/dev/null 2>&1; then
    fail "$label verification should fail closed"
  fi
}

assert_bad_managed_import_map_fails_closed 'malformed managed import map' malformed
assert_bad_managed_import_map_fails_closed 'duplicate managed import maps' duplicate
assert_bad_managed_import_map_fails_closed 'wrong managed import-map target' wrong-target
assert_bad_managed_import_map_fails_closed 'unsafe managed import-map target' unsafe-target
assert_bad_managed_import_map_fails_closed 'fragment managed import-map target' unsafe-fragment
assert_bad_managed_import_map_fails_closed 'conflicting unmanaged import map' conflicting-unmanaged

assert_forged_managed_marker_fails_closed() {
  reset_shutdown_ui_fixture
  printf 'before;%s;after\n' "$source_region" > "$FAKE_UI_ASSET_DIR/index-7c0be990.js"
  write_shutdown_index '/assets/index-7c0be990.js'
  patch_umbrel_shutdown_ui
  local generated_name before_index after_index patch_exit verify_exit
  generated_name="$(basename "$(compgen -G "$FAKE_UI_ASSET_DIR/index-7c0be990.m1s-*.js")")"
  printf '<script type="importmap" title="x data-m1s-shutdown-ui z">{"imports":{"/assets/index-7c0be990.js":"/assets/%s"}}</script>\n<script type="module" src="/assets/%s"></script>\n' "$generated_name" "$generated_name" > "$FAKE_UI_ROOT/index.html"
  before_index="$(<"$FAKE_UI_ROOT/index.html")"
  if patch_umbrel_shutdown_ui >/dev/null 2>&1; then patch_exit=0; else patch_exit=$?; fi
  if verify_umbrel_shutdown_ui >/dev/null 2>&1; then verify_exit=0; else verify_exit=$?; fi
  after_index="$(<"$FAKE_UI_ROOT/index.html")"
  [[ "$patch_exit" -ne 0 && "$verify_exit" -ne 0 ]] || fail "forged title marker must be rejected by patch and verification: patch_exit=$patch_exit verify_exit=$verify_exit"
  assert_eq "$before_index" "$after_index" 'forged title marker must not mutate index.html'
}

assert_forged_managed_marker_fails_closed

reset_shutdown_ui_fixture
printf 'before;%s;after\n' "$source_region" > "$FAKE_UI_ASSET_DIR/index-7c0be990.js"
write_shutdown_index '/assets/index-7c0be990.js'
patch_umbrel_shutdown_ui
rm "$FAKE_UI_ASSET_DIR/index-7c0be990.js"
assert_patch_fails_without_index_mutation 'missing original immutable asset'

reset_shutdown_ui_fixture
printf 'before;%s;after\n' "$source_region" > "$FAKE_UI_ASSET_DIR/index-7c0be990.js"
printf '<script type="importmap" data-m1s-shutdown-ui>{"imports":{"/assets/index-7c0be990.js":"/assets/index-7c0be990.m1s-deadbeefcafe.js"}}</script><script type="module" src="/assets/index-7c0be990.m1s-deadbeefcafe.js"></script>\n' > "$FAKE_UI_ROOT/index.html"
assert_patch_fails_without_index_mutation 'missing generated target asset'

reset_shutdown_ui_fixture
printf 'before;%s;after\n' "$source_region" > "$FAKE_UI_ASSET_DIR/index-7c0be990.js"
write_shutdown_index '/assets/index-7c0be990.js'
patch_umbrel_shutdown_ui
printf 'stale;%s\n' "$canonical_region" > "$FAKE_UI_ASSET_DIR/index-7c0be990.m1s-000000000000.js"
assert_patch_fails_without_index_mutation 'stale generated asset after canonical patch'

reset_shutdown_ui_fixture
printf 'before;%s;%s;after\n' "$source_region" "$source_region" > "$FAKE_UI_ASSET_DIR/index-7c0be990.js"
write_shutdown_index '/assets/index-7c0be990.js'
assert_patch_fails_without_index_mutation 'duplicate source branches'

reset_shutdown_ui_fixture
printf 'before;%s;%s;%s;after\n' "$source_region" "$public_region" "$canonical_region" > "$FAKE_UI_ASSET_DIR/index-7c0be990.js"
write_shutdown_index '/assets/index-7c0be990.js'
assert_patch_fails_without_index_mutation 'mixed source/30/75 branches'

reset_shutdown_ui_fixture
printf 'before;%s;after\n' "$source_region" > "$FAKE_UI_ASSET_DIR/index-7c0be990.js"
printf '<script type="module" src="/assets/index-7c0be990.js"></script><script type="module" src="/assets/index-7c0be990.js"></script>\n' > "$FAKE_UI_ROOT/index.html"
assert_patch_fails_without_index_mutation 'duplicate index asset references'

reset_shutdown_ui_fixture
printf 'before;%s;after\n' "$source_region" > "$FAKE_UI_ASSET_DIR/index-7c0be990.js"
assert_patch_fails_without_index_mutation 'missing index'

reset_shutdown_ui_fixture
write_shutdown_index '/assets/index-7c0be990.js'
assert_patch_fails_without_index_mutation 'missing referenced asset'

reset_shutdown_ui_fixture
printf 'before;%s;after\n' "$source_region" > "$FAKE_UI_ASSET_DIR/index-7c0be990.css"
write_shutdown_index '/assets/index-7c0be990.css'
assert_patch_fails_without_index_mutation 'non-JS index reference'

reset_shutdown_ui_fixture
printf 'before;%s;after\n' "$source_region" > "$FAKE_UI_ROOT/escape.js"
write_shutdown_index '/assets/../escape.js'
assert_patch_fails_without_index_mutation 'path traversal index reference'

reset_shutdown_ui_fixture
printf 'before;%s;after\n' "$source_region" > "$FAKE_UI_ASSET_DIR/index-7c0be990.js"
write_shutdown_index '/assets/index-7c0be990.js?unsafe'
assert_patch_fails_without_index_mutation 'query-bearing index reference'

reset_shutdown_ui_fixture
printf 'before;%s;after\n' "$source_region" > "$FAKE_UI_ASSET_DIR/index-7c0be990.js"
write_shutdown_index '/assets/index-7c0be990.js#unsafe'
assert_patch_fails_without_index_mutation 'fragment-bearing index reference'

reset_shutdown_ui_fixture
printf 'before;%s;after\n' "$canonical_region" > "$FAKE_UI_ASSET_DIR/index-7c0be990.m1s-deadbeefcafe.js"
write_shutdown_index '/assets/index-7c0be990.m1s-deadbeefcafe.js'
assert_patch_fails_without_index_mutation 'mismatched filename hash'

reset_shutdown_ui_fixture
printf 'before;%s;after\n' "$source_region" > "$FAKE_UI_ASSET_DIR/index-7c0be990.js"
printf 'stale;%s\n' "$canonical_region" > "$FAKE_UI_ASSET_DIR/index-7c0be990.m1s-000000000000.js"
write_shutdown_index '/assets/index-7c0be990.js'
assert_patch_fails_without_index_mutation 'stale generated hashed asset'
)
pass "Installer writes a deterministic 75s hashed shutdown UI asset and fails closed"

record_install_state
state_text="$(<"$INSTALL_STATE_FILE")"
assert_contains "$state_text" '"version": "0.5.28"' "Success state must declare the managed 0.5.28 version"
assert_contains "$state_text" "\"image\": \"$EXPECTED_UMBREL_IMAGE\"" "Success state must use the live exact image ref"
assert_contains "$state_text" "\"image_id\": \"$DEFAULT_RESOLVED_UMBREL_IMAGE_ID\"" "Success state must use Docker's resolved local image ID"

CUSTOM_UMBREL_IMAGE='example.invalid/umbrel:custom-arm64'
CUSTOM_UMBREL_IMAGE_ID='sha256:custom-arm64-image-id'
rm -f "$INSTALL_STATE_FILE"
IMAGE="$CUSTOM_UMBREL_IMAGE"
FAKE_PULLED_IMAGE_ID="$CUSTOM_UMBREL_IMAGE_ID"
FAKE_LIVE_IMAGE_ID="$CUSTOM_UMBREL_IMAGE_ID"
FAKE_LIVE_IMAGE_REF="$CUSTOM_UMBREL_IMAGE"
FAKE_PULLED_ARCHITECTURE='arm64'
pull_and_verify_umbrel_image
assert_eq "$CUSTOM_UMBREL_IMAGE_ID" "$RESOLVED_UMBREL_IMAGE_ID" "Custom arm64 pull must retain its resolved image ID"
wait_for_umbrel_runtime_health
record_install_state
custom_state_text="$(<"$INSTALL_STATE_FILE")"
assert_contains "$custom_state_text" "\"image\": \"$CUSTOM_UMBREL_IMAGE\"" "Custom arm64 success state must use the live custom image ref"
assert_contains "$custom_state_text" "\"image_id\": \"$CUSTOM_UMBREL_IMAGE_ID\"" "Custom arm64 success state must use the live custom image ID"

FAKE_LIVE_IMAGE_ID='sha256:stale-custom-image-id'
set +e
stale_custom_runtime_output="$(wait_for_umbrel_runtime_health 2>&1)"
stale_custom_runtime_status=$?
set -e
[[ "$stale_custom_runtime_status" -ne 0 ]] || fail "Stale custom live image ID must fail the runtime-health gate"
assert_contains "$stale_custom_runtime_output" 'pulled arm64 image ID' "Stale custom runtime must explain the resolved image-ID mismatch"

FAKE_LIVE_IMAGE_ID="$CUSTOM_UMBREL_IMAGE_ID"
FAKE_LIVE_IMAGE_REF='example.invalid/umbrel:wrong-live-ref'
set +e
wrong_live_ref_output="$(wait_for_umbrel_runtime_health 2>&1)"
wrong_live_ref_status=$?
set -e
[[ "$wrong_live_ref_status" -ne 0 ]] || fail "Wrong live image ref must fail the runtime-health gate"
assert_contains "$wrong_live_ref_output" 'image ref' "Wrong live ref must explain the exact image-ref mismatch"

IMAGE="$EXPECTED_UMBREL_IMAGE"
FAKE_PULLED_IMAGE_ID="$DEFAULT_RESOLVED_UMBREL_IMAGE_ID"
FAKE_LIVE_IMAGE_ID="$DEFAULT_RESOLVED_UMBREL_IMAGE_ID"
FAKE_LIVE_IMAGE_REF="$EXPECTED_UMBREL_IMAGE"
FAKE_PULLED_ARCHITECTURE='arm64'
pull_and_verify_umbrel_image
rm -f "$INSTALL_STATE_FILE"
FAKE_TOPLEVEL_STATE='exited'
: > "$RUNTIME_DOCKER_LOG"
set +e
unhealthy_runtime_output="$(wait_for_umbrel_runtime_health 2>&1)"
unhealthy_runtime_status=$?
set -e
[[ "$unhealthy_runtime_status" -ne 0 ]] || fail "Unhealthy top-level container must fail the runtime-health gate"
assert_not_contains "$unhealthy_runtime_output" 'Install state written' "Unhealthy runtime must not emit a success-state marker"
[[ ! -e "$INSTALL_STATE_FILE" ]] || fail "Unhealthy runtime must not write install state"
assert_contains "$(<"$RUNTIME_DOCKER_LOG")" 'sleep 0' "Unhealthy runtime must use the configured bounded polling delay without real waits"

FAKE_TOPLEVEL_STATE='running'
FAKE_CANONICAL_TOR_IMAGE='ghcr.io/getumbrel/tor:0.4.9.10'
set +e
wrong_tor_runtime_output="$(wait_for_umbrel_runtime_health 2>&1)"
wrong_tor_runtime_status=$?
set -e
[[ "$wrong_tor_runtime_status" -ne 0 ]] || fail "Wrong Tor image must fail the runtime-health gate"
assert_not_contains "$wrong_tor_runtime_output" 'Install state written' "Wrong Tor runtime must not emit a success-state marker"
[[ ! -e "$INSTALL_STATE_FILE" ]] || fail "Wrong Tor runtime must not write install state"

FAKE_CANONICAL_TOR_IMAGE="$EXPECTED_TOR_PROXY_IMAGE"
FAKE_CANONICAL_AUTH_STATE='exited'
set +e
missing_auth_runtime_output="$(wait_for_umbrel_runtime_health 2>&1)"
missing_auth_runtime_status=$?
set -e
[[ "$missing_auth_runtime_status" -ne 0 ]] || fail "Missing auth runtime must fail the runtime-health gate"
assert_not_contains "$missing_auth_runtime_output" 'Install state written' "Missing auth runtime must not emit a success-state marker"
[[ ! -e "$INSTALL_STATE_FILE" ]] || fail "Missing auth runtime must not write install state"

FAKE_CANONICAL_AUTH_STATE='running'
IMAGE="$CUSTOM_UMBREL_IMAGE"
FAKE_PULLED_IMAGE_ID=''
FAKE_PULLED_ARCHITECTURE='arm64'
: > "$RUNTIME_DOCKER_LOG"
set +e
missing_metadata_output="$(pull_and_verify_umbrel_image 2>&1)"
missing_metadata_status=$?
set -e
[[ "$missing_metadata_status" -ne 0 ]] || fail "Missing pulled image metadata must fail before docker run"
assert_contains "$missing_metadata_output" 'expected arm64 image ID' "Missing image metadata must explain the failed arm64 identity check"
assert_not_contains "$(<"$RUNTIME_DOCKER_LOG")" 'docker run' "Missing custom metadata must fail before docker run"

FAKE_PULLED_IMAGE_ID="$CUSTOM_UMBREL_IMAGE_ID"
FAKE_PULLED_ARCHITECTURE='amd64'
: > "$RUNTIME_DOCKER_LOG"
set +e
wrong_architecture_output="$(pull_and_verify_umbrel_image 2>&1)"
wrong_architecture_status=$?
set -e
[[ "$wrong_architecture_status" -ne 0 ]] || fail "Non-arm64 custom image metadata must fail before docker run"
assert_contains "$wrong_architecture_output" 'architecture' "Non-arm64 custom image metadata must explain the architecture rejection"
assert_not_contains "$(<"$RUNTIME_DOCKER_LOG")" 'docker run' "Non-arm64 custom metadata must fail before docker run"

pass "Exact image and bounded runtime-health checks gate success state"

printf '[unit] installer interactive tests complete\n'
