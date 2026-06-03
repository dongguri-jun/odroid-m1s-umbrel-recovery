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

printf '[unit] installer interactive tests complete\n'
