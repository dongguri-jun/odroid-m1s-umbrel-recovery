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
    ;;
  -nrpo\ MOUNTPOINT\ /dev/*)
    exit 0
    ;;
  -nrpo\ NAME,TYPE\ /dev/*)
    printf '%s disk\n' "$4"
    ;;
  *)
    exit 0
    ;;
esac
STUB
chmod +x "$TEST_TMPDIR/bin/lsblk"
PATH="$TEST_TMPDIR/bin:$PATH"

# shellcheck source=scripts/m1s-clean-install-umbrel.sh
M1S_INSTALLER_LIB_ONLY=1 source scripts/m1s-clean-install-umbrel.sh

ROOT_DISK="mmcblk0"
TARGET_INPUT=""

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

printf '[unit] installer interactive tests complete\n'
