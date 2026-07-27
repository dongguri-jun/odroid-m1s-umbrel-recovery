#!/usr/bin/env bash
set -Eeuo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

# shellcheck source=scripts/m1s-support-policy.sh
source scripts/m1s-support-policy.sh

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
  [[ "$haystack" != *"$needle"* ]] || fail "$label: unexpectedly found '$needle'"
}

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

TEST_TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TEST_TMPDIR"' EXIT

supported_model='Hardkernel ODROID-M1S'
supported_kernel='5.10.160-odroid-arm64'
fixture_os_id=ubuntu
fixture_os_version=22.04
fixture_kernel_release="$supported_kernel"
fixture_architecture=aarch64
fixture_model="$supported_model"

m1s_host_os_id() { printf '%s' "$fixture_os_id"; }
m1s_host_os_version() { printf '%s' "$fixture_os_version"; }
m1s_host_kernel_release() { printf '%s' "$fixture_kernel_release"; }
m1s_host_architecture() { printf '%s' "$fixture_architecture"; }
m1s_host_model() { printf '%s' "$fixture_model"; }

assert_supported() {
  m1s_validate_supported_host_values ubuntu 22.04 "$supported_kernel" aarch64 "$supported_model" \
    || fail 'exact ODROID M1S, Ubuntu 22.04, and Linux 5.10.x must be supported'
}

assert_rejected() {
  local os_id="$1"
  local os_version="$2"
  local kernel_release="$3"
  local architecture="$4"
  local model="$5"
  if m1s_validate_supported_host_values "$os_id" "$os_version" "$kernel_release" "$architecture" "$model"; then
    fail "unsupported fixture unexpectedly passed: $os_id/$os_version/$kernel_release/$architecture/$model"
  fi
}

printf '[unit] exact validated-profile fixture matrix\n'
assert_supported
assert_rejected ubuntu 20.04 "$supported_kernel" aarch64 "$supported_model"
assert_rejected ubuntu 24.04 "$supported_kernel" aarch64 "$supported_model"
assert_rejected ubuntu 22.04 6.1.0-odroid-arm64 aarch64 "$supported_model"
assert_rejected ubuntu 22.04 5.10 aarch64 "$supported_model"
assert_rejected ubuntu 22.04 "$supported_kernel" x86_64 "$supported_model"
assert_rejected ubuntu 22.04 "$supported_kernel" aarch64 'Hardkernel ODROID-M1'
assert_rejected Ubuntu 22.04 "$supported_kernel" aarch64 "$supported_model"
assert_rejected ubuntu '22.04 ' "$supported_kernel" aarch64 "$supported_model"
assert_rejected ubuntu 22.04 "$supported_kernel" aarch64 'hardkernel odroid-m1s'
assert_rejected ubuntu 22.04 "$supported_kernel" aarch64 'Hardkernel ODROID-M1S '
pass 'validator accepts only the exact supported host identity'

run_policy_fixture() {
  local fixture_name="$1"
  local os_id="$2"
  local os_version="$3"
  local kernel_release="$4"
  local architecture="$5"
  local model="$6"
  local output_file="$TEST_TMPDIR/$fixture_name-output"
  local status

  fixture_os_id="$os_id"
  fixture_os_version="$os_version"
  fixture_kernel_release="$kernel_release"
  fixture_architecture="$architecture"
  fixture_model="$model"
  set +e
  m1s_report_host_support >"$output_file" 2>&1
  status=$?
  set -e

  printf '%s\n' "$status"
}

supported_status="$(run_policy_fixture supported ubuntu 22.04 "$supported_kernel" aarch64 "$supported_model")"
assert_eq 0 "$supported_status" 'validated fixture should pass the host-profile reporter'
assert_eq '' "$(<"$TEST_TMPDIR/supported-output")" 'validated fixture should not print an unvalidated-host warning'

for fixture in ubuntu-20 ubuntu-24 linux-61 wrong-board missing-os malformed-os missing-model missing-kernel; do
  case "$fixture" in
    ubuntu-20) status="$(run_policy_fixture "$fixture" ubuntu 20.04 "$supported_kernel" aarch64 "$supported_model")" ;;
    ubuntu-24) status="$(run_policy_fixture "$fixture" ubuntu 24.04 "$supported_kernel" aarch64 "$supported_model")" ;;
    linux-61) status="$(run_policy_fixture "$fixture" ubuntu 22.04 6.1.0-odroid-arm64 aarch64 "$supported_model")" ;;
    wrong-board) status="$(run_policy_fixture "$fixture" ubuntu 22.04 "$supported_kernel" aarch64 'Generic ARM board')" ;;
    missing-os) status="$(run_policy_fixture "$fixture" '' 22.04 "$supported_kernel" aarch64 "$supported_model")" ;;
    malformed-os) status="$(run_policy_fixture "$fixture" 'ubuntu=' 22.04 "$supported_kernel" aarch64 "$supported_model")" ;;
    missing-model) status="$(run_policy_fixture "$fixture" ubuntu 22.04 "$supported_kernel" aarch64 '')" ;;
    missing-kernel) status="$(run_policy_fixture "$fixture" ubuntu 22.04 '' aarch64 "$supported_model")" ;;
  esac
  assert_eq 0 "$status" "$fixture must warn and continue"
  output="$(<"$TEST_TMPDIR/$fixture-output")"
  assert_contains "$output" 'Host is outside the validated profile; continuing without blocking.' "$fixture should report non-blocking policy output"
  assert_contains "$output" 'Validated profile: ODROID M1S / Ubuntu 22.04 Server / Linux 5.10.x (arm64).' "$fixture warning should name the validated profile"
done

rejected_output="$(<"$TEST_TMPDIR/wrong-board-output")"
assert_not_contains "$rejected_output" 'Generic ARM board' 'policy warnings must not expose detected model identifiers'
assert_not_contains "$rejected_output" "$TEST_TMPDIR" 'policy warnings must not expose fixture paths'
pass 'sourced helper fixtures warn and continue without exposing observed identifiers'

os_release_fixture="$TEST_TMPDIR/os-release"
printf 'ID=ubuntu\nVERSION_ID=22.04\n' > "$os_release_fixture"
assert_eq ubuntu "$(m1s_os_release_value "$os_release_fixture" ID)" 'os-release parser should retain the exact Ubuntu identity'
printf 'ID=ubuntu\nVERSION_ID="22.04\n' > "$os_release_fixture"
if m1s_os_release_value "$os_release_fixture" VERSION_ID >/dev/null 2>&1; then
  fail 'malformed os-release must fail closed'
fi
if m1s_os_release_value "$TEST_TMPDIR/missing-os-release" ID >/dev/null 2>&1; then
  fail 'missing os-release must fail closed'
fi
pass 'os-release parser rejects malformed and unreadable inputs'

fixture_os_id=ubuntu
fixture_os_version=22.04
fixture_kernel_release="$supported_kernel"
fixture_architecture=aarch64
fixture_model="$supported_model"
m1s_report_host_support
assert_eq 1 "$M1S_SUPPORTED_HOST_VERIFIED" 'successful policy check must set verified state'
m1s_supported_host_is_verified || fail 'verified-state reader must report a validated host'
fixture_os_version=24.04
m1s_report_host_support >/dev/null 2>&1 || fail 'unvalidated host reporter must not block during state reset regression'
assert_eq 0 "$M1S_SUPPORTED_HOST_VERIFIED" 'unvalidated policy check must clear stale verified state'
if m1s_supported_host_is_verified; then
  fail 'verified-state reader must reject an unvalidated host without blocking the reporter'
fi
fixture_os_version=22.04
m1s_report_host_support
assert_eq 1 "$M1S_SUPPORTED_HOST_VERIFIED" 'subsequent successful policy check must restore verified state'
pass 'verification state follows the validated unvalidated validated matrix without blocking'

policy_text="$(<scripts/m1s-support-policy.sh)"
assert_not_contains "${policy_text,,}" 'wifi' 'support policy must not contain Wi-Fi behavior'
assert_not_contains "${policy_text,,}" 'nmcli' 'support policy must not contain NetworkManager behavior'
assert_not_contains "$policy_text" 'M1S_SUPPORT_POLICY_TEST_MODE' 'policy must not expose an environment-controlled test mode'
assert_not_contains "$policy_text" 'M1S_OS_ID_OVERRIDE' 'policy must not trust inherited OS identity overrides'
pass 'support policy has no network ownership behavior'

printf '[unit] public entrypoints report unvalidated hosts before mutation\n'
installer_text="$(<scripts/m1s-clean-install-umbrel.sh)"
updater_text="$(<scripts/m1s-update-umbrel.sh)"
system_updater_text="$(<scripts/m1s-update-system-packages.sh)"
initial_setup_text="$(<scripts/m1s-initial-setup.sh)"
recovery_common_text="$(<scripts/bitcoin-recovery-common.sh)"
system_updater_main="${system_updater_text#*main() \{}"
recovery_start_text="${recovery_common_text#*run_recovery_start() \{}"
recovery_status_text="${recovery_common_text#*run_recovery_status_check() \{}"

assert_before "$installer_text" 'm1s_report_host_support' 'info "Stopping and removing Incus containers if present"' 'installer warning must precede host mutation'
assert_before "$updater_text" 'm1s_report_host_support' 'sync_repository_to_origin_main "$@"' 'updater warning must precede repository sync'
assert_before "$system_updater_main" 'm1s_report_host_support' 'apt_update_command' 'system package warning must precede apt mutation'
assert_before "$initial_setup_text" 'm1s_report_host_support' 'read -r -p "Enter new username: "' 'initial setup warning must precede mutation input collection'
assert_before "$recovery_start_text" 'm1s_report_host_support' 'ensure_state_dir' 'recovery start warning must precede state mutation'
assert_before "$recovery_status_text" 'm1s_report_host_support' 'record_last_observed_state' 'recovery status warning must precede state mutation'
assert_not_contains "$installer_text$updater_text$system_updater_text$initial_setup_text$recovery_common_text" 'm1s_require_supported_host' 'public entrypoint flows must not retain the blocking host gate'
pass 'every public entrypoint warns before mutation without retaining a host-policy block'

printf '[unit] support policy tests complete\n'
