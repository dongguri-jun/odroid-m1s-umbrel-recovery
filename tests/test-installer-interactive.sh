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
assert_contains "$one_command_recovery_output" "Applying boot-time NVMe mitigation and rebooting once" "One-command flow should promise automatic reboot recovery"
assert_contains "$one_command_recovery_output" "apply_nvme_boot_mitigation" "One-command flow should apply NVMe mitigation before reboot"
assert_contains "$one_command_recovery_output" "write_preinstall_resume_state" "One-command flow should persist resume state"
assert_contains "$one_command_recovery_output" "install_preinstall_resume_unit" "One-command flow should install the resume unit"
assert_contains "$one_command_recovery_output" "[DRY-RUN] systemctl reboot" "One-command flow should reboot automatically in dry-run"
assert_not_contains "$one_command_recovery_output" "explicit /dev/nvme0n1 target is supplied" "One-command flow must not require an explicit target anymore"
pass "Missing NVMe now triggers automatic one-command recovery without an explicit target"

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
assert_eq "1234 2222 3333 4444" "$busy_pids" "Busy PID collection should deduplicate target-scoped holders"
killable_pids="$(filter_killable_target_pids 1234 2222 3333 4444 2>/dev/null | paste -sd ' ' -)"
assert_eq "1234 2222" "$killable_pids" "Protected SSH and installer PIDs should not be killable"
stop_target_busy_processes >/dev/null 2>&1
kill_log="$(<"$KILL_LOG")"
assert_contains "$kill_log" "-TERM 1234" "First pass should send SIGTERM to the first killable SSD holder"
assert_contains "$kill_log" "-TERM 2222" "First pass should send SIGTERM to the second killable SSD holder"
assert_not_contains "$kill_log" "-TERM 3333" "Protected sshd PID must not receive SIGTERM"
assert_not_contains "$kill_log" "-TERM 4444" "Installer PID must not receive SIGTERM"
assert_not_contains "$kill_log" "-KILL 1234" "PID gone after TERM must not receive SIGKILL"
assert_contains "$kill_log" "-KILL 2222" "Only the remaining killable SSD holder should receive SIGKILL"
pass "Target-scoped SSD busy cleanup uses TERM before scoped KILL and preserves protected PIDs"

printf '[unit] installer interactive tests complete\n'
