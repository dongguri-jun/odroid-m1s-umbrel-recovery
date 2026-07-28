#!/usr/bin/env bash
set -Eeuo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

# shellcheck source=scripts/m1s-update-umbrel.sh
source scripts/m1s-update-umbrel.sh

m1s_host_os_id() { printf 'ubuntu'; }
m1s_host_os_version() { printf '22.04'; }
m1s_host_kernel_release() { printf '5.10.160-odroid-arm64'; }
m1s_host_architecture() { printf 'aarch64'; }
m1s_host_model() { printf 'Hardkernel ODROID-M1S'; }

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
  local needle="$1"
  local haystack="$2"
  local label="$3"
  [[ "$haystack" == *"$needle"* ]] || fail "$label: missing '$needle'"
}

assert_not_contains() {
  local needle="$1"
  local haystack="$2"
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

read_json_value() {
  local file="$1"
  local expression="$2"
  python3 - "$file" "$expression" <<'PY'
import json, sys
with open(sys.argv[1]) as f:
    data = json.load(f)
value = eval(sys.argv[2], {"data": data})
print("null" if value is None else value)
PY
}

assert_json_eq() {
  local file="$1"
  local expression="$2"
  local expected="$3"
  local label="$4"
  local actual
  actual="$(python3 - "$file" "$expression" <<'PY'
import json, sys
path, expression = sys.argv[1:3]
with open(path) as f:
    data = json.load(f)
value = eval(expression, {"data": data})
if value is None:
    print("null")
elif isinstance(value, bool):
    print("true" if value else "false")
elif isinstance(value, list):
    print("\n".join(str(item) for item in value))
else:
    print(value)
PY
)"
  assert_eq "$expected" "$actual" "$label"
}

assert_json_missing() {
  local file="$1"
  local key="$2"
  python3 - "$file" "$key" <<'PY' || fail "expected JSON key to be missing: $key"
import json, sys
path, key = sys.argv[1:3]
with open(path) as f:
    data = json.load(f)
sys.exit(0 if key not in data else 1)
PY
}

assert_json_semantically_equal_excluding_updated_at() {
  local before_file="$1"
  local after_file="$2"
  local label="$3"
  python3 - "$before_file" "$after_file" <<'PY' || fail "$label"
import json
import sys

before_path, after_path = sys.argv[1:3]
with open(before_path) as before_file:
    before = json.load(before_file)
with open(after_path) as after_file:
    after = json.load(after_file)
before.pop("updated_at", None)
after.pop("updated_at", None)
sys.exit(0 if before == after else 1)
PY
}

new_test_state() {
  TEST_TMPDIR="$(mktemp -d)"
  INSTALL_STATE_DIR="$TEST_TMPDIR/etc/umbrel-recovery"
  INSTALL_STATE_FILE="$INSTALL_STATE_DIR/installed.json"
  DATA_DIR="$TEST_TMPDIR/mnt/fullnode"
  FSTAB_FILE="$TEST_TMPDIR/etc/fstab"
  DRY_RUN=0
  CHECK_ONLY=0
  mkdir -p "$DATA_DIR" "$(dirname "$FSTAB_FILE")"
}

cleanup_test_state() {
  if [[ -n "${TEST_TMPDIR:-}" && -d "$TEST_TMPDIR" ]]; then
    rm -rf "$TEST_TMPDIR"
  fi
  unset TEST_TMPDIR || true
  unset M1S_TEST_ALLOW_NON_BLOCK_TARGET || true
  unset M1S_TEST_TARGET_UUID || true
}

with_test_state() {
  cleanup_test_state
  new_test_state
}

new_auto_sync_test_repo() {
  TEST_TMPDIR="$(mktemp -d)"
  AUTO_SYNC_REPO_ROOT_OVERRIDE="$TEST_TMPDIR/repo"
  mkdir -p "$AUTO_SYNC_REPO_ROOT_OVERRIDE/.git" "$AUTO_SYNC_REPO_ROOT_OVERRIDE/scripts" "$TEST_TMPDIR/bin"
  : > "$AUTO_SYNC_REPO_ROOT_OVERRIDE/scripts/m1s-update-umbrel.sh"
  export AUTO_SYNC_REPO_ROOT_OVERRIDE
  export FAKE_GIT_LOG="$TEST_TMPDIR/git.log"
  export FAKE_BASH_LOG="$TEST_TMPDIR/bash.log"
  export FAKE_ORIGIN_URL="https://github.com/dongguri-jun/odroid-m1s-umbrel-recovery.git"
  export FAKE_HEAD="old-head"
  export FAKE_ORIGIN_HEAD="old-head"
  export FAKE_FETCH_FAIL=0
  export FAKE_ORIGIN_MAIN_MISSING=0
  : > "$FAKE_GIT_LOG"
  : > "$FAKE_BASH_LOG"
  cat > "$TEST_TMPDIR/bin/git" <<'EOF'
#!/bin/bash
set -Eeuo pipefail
printf '%s\n' "$*" >> "$FAKE_GIT_LOG"
while [[ $# -gt 0 ]]; do
  case "$1" in
    -c)
      shift 2
      ;;
    -C)
      shift 2
      ;;
    *)
      break
      ;;
  esac
done
case "${1:-}" in
  rev-parse)
    case "${2:-}" in
      HEAD)
        printf '%s\n' "$FAKE_HEAD"
        ;;
      origin/main)
        [[ "${FAKE_ORIGIN_MAIN_MISSING:-0}" -eq 0 ]] || exit 1
        printf '%s\n' "$FAKE_ORIGIN_HEAD"
        ;;
      *)
        exit 1
        ;;
    esac
    ;;
  remote)
    [[ "${2:-}" == "get-url" && "${3:-}" == "origin" ]] || exit 1
    printf '%s\n' "$FAKE_ORIGIN_URL"
    ;;
  fetch)
    [[ "${FAKE_FETCH_FAIL:-0}" -eq 0 ]] || exit 1
    [[ "${2:-}" == "origin" ]] || exit 1
    ;;
  reset)
    [[ "${2:-}" == "--hard" && "${3:-}" == "origin/main" ]] || exit 1
    ;;
  *)
    exit 1
    ;;
esac
EOF
  cat > "$TEST_TMPDIR/bin/bash" <<'EOF'
#!/bin/bash
set -Eeuo pipefail
printf '%s\n' "$*" > "$FAKE_BASH_LOG"
exit 42
EOF
  chmod +x "$TEST_TMPDIR/bin/git" "$TEST_TMPDIR/bin/bash"
  PATH="$TEST_TMPDIR/bin:$PATH"
  export PATH
}

printf '[unit] updater migration plan\n'
updater_script="$(<scripts/m1s-update-umbrel.sh)"
assert_contains 'm1s-support-policy.sh' "$updater_script" 'Updater must source the shared support policy'
updater_main="${updater_script#*$'main() {\n'}"
assert_before "$updater_main" 'm1s_report_host_support' 'sync_repository_to_origin_main "$@"' 'Updater must report unvalidated hosts before repository sync'
assert_before "$updater_main" 'm1s_report_host_support' 'ensure_fullnode_mount_from_state repair' 'Updater must report unvalidated hosts before mount repair'
[[ "$updater_main" == *'m1s_report_host_support'*'global_preflight'* ]] \
  || fail 'Updater must report unvalidated hosts before global preflight'
pass 'updater host-profile warning precedes every mutating preflight'
with_test_state
assert_plan_from_version() {
  local current="$1"
  local expected_first="${2:-}"
  local expected_count=0
  local expected_last="${MIGRATIONS[$((${#MIGRATIONS[@]} - 1))]}"
  for step in "${MIGRATIONS[@]}"; do
    local to_version
    to_version="$(step_to_version "$step")"
    if version_lt "$current" "$to_version"; then
      expected_count=$((expected_count + 1))
    fi
  done
  build_migration_plan "$current"
  assert_eq "$expected_count" "${#PLANNED_MIGRATIONS[@]}" "$current should plan the expected remaining migrations"
  if [[ "$expected_count" -gt 0 ]]; then
    assert_eq "$expected_first" "${PLANNED_MIGRATIONS[0]}" "$current first planned migration"
    assert_eq "$expected_last" "${PLANNED_MIGRATIONS[$((${#PLANNED_MIGRATIONS[@]} - 1))]}" "$current final planned migration"
  fi
}
assert_plan_from_version "0.1.0" "0.1.0_to_0.2.0"
assert_plan_from_version "0.4.5" "0.4.5_to_0.4.6"
assert_plan_from_version "0.4.7" "0.4.7_to_0.4.8"
assert_plan_from_version "0.4.8" "0.4.8_to_0.4.9"
assert_plan_from_version "0.4.9" "0.4.9_to_0.4.10"
assert_plan_from_version "0.4.10" "0.4.10_to_0.4.11"
assert_plan_from_version "0.4.11" "0.4.11_to_0.4.12"
assert_plan_from_version "0.4.12" "0.4.12_to_0.4.13"
assert_plan_from_version "0.4.13" "0.4.13_to_0.4.14"
assert_plan_from_version "0.4.14" "0.4.14_to_0.4.15"
assert_plan_from_version "0.4.15" "0.4.15_to_0.4.16"
assert_plan_from_version "0.4.16" "0.4.16_to_0.4.17"
assert_plan_from_version "0.4.17" "0.4.17_to_0.4.18"
assert_plan_from_version "0.4.18" "0.4.18_to_0.5.0"
assert_plan_from_version "0.5.0" "0.5.0_to_0.5.1"
assert_plan_from_version "0.5.1" "0.5.1_to_0.5.2"
assert_plan_from_version "0.5.2" "0.5.2_to_0.5.3"
assert_plan_from_version "0.5.3" "0.5.3_to_0.5.4"
assert_plan_from_version "0.5.4" "0.5.4_to_0.5.5"
assert_plan_from_version "0.5.5" "0.5.5_to_0.5.6"
assert_plan_from_version "0.5.6" "0.5.6_to_0.5.7"
assert_plan_from_version "0.5.7" "0.5.7_to_0.5.8"
assert_plan_from_version "0.5.8" "0.5.8_to_0.5.9"
assert_plan_from_version "0.5.9" "0.5.9_to_0.5.10"
assert_plan_from_version "0.5.10" "0.5.10_to_0.5.11"
assert_plan_from_version "0.5.11" "0.5.11_to_0.5.12"
assert_plan_from_version "0.5.12" "0.5.12_to_0.5.13"
assert_plan_from_version "0.5.13" "0.5.13_to_0.5.14"
assert_plan_from_version "0.5.14" "0.5.14_to_0.5.15"
assert_plan_from_version "0.5.15" "0.5.15_to_0.5.16"
assert_plan_from_version "0.5.21" "0.5.21_to_0.5.22"
assert_plan_from_version "0.5.22" "0.5.22_to_0.5.23"
assert_plan_from_version "0.5.23" "0.5.23_to_0.5.24"
assert_plan_from_version "0.5.25" "0.5.25_to_0.5.26"
assert_plan_from_version "0.5.30" "0.5.30_to_0.5.31"

assert_invalid_migration_plan() {
  local current="$1"
  local plan_output plan_output_file plan_status

  PLANNED_MIGRATIONS=(unexpected-step)
  plan_output_file="$TEST_TMPDIR/invalid-version-plan.out"
  set +e
  build_migration_plan "$current" >"$plan_output_file" 2>&1
  plan_status=$?
  set -e
  plan_output="$(<"$plan_output_file")"
  [[ "$plan_status" -ne 0 ]] || fail "invalid version <$current> must reject migration planning"
  assert_eq "" "${PLANNED_MIGRATIONS[*]}" "invalid version <$current> clears planned migrations"
  assert_contains "Invalid installed version format" "$plan_output" "invalid version <$current> reports a generalized planning error"
}

for invalid_version in "" "unknown" "0.5.x" " " "0.5" "0.5.26.1" "-1.0.0" "0.5.-1" "0.x.0" "0.5.26; echo injected"; do
  assert_invalid_migration_plan "$invalid_version"
done

if [[ "${M1S_TEST_CHARACTERIZE_CURRENT_VERSION_BYPASS:-0}" -eq 1 ]]; then
  printf '[unit] current-version stopped-runtime bypass baseline characterization\n'
  with_test_state
  main_mutation_marker="$TEST_TMPDIR/current-version-mount-repair"
  main_truth_marker="$TEST_TMPDIR/current-version-runtime-truth"
  set +e
  main_current_output="$(M1S_TEST_MUTATION_MARKER="$main_mutation_marker" M1S_TEST_TRUTH_MARKER="$main_truth_marker" bash -c '
set -Eeuo pipefail
source scripts/m1s-update-umbrel.sh
m1s_host_os_id() { printf "ubuntu"; }
m1s_host_os_version() { printf "22.04"; }
m1s_host_kernel_release() { printf "5.10.160-odroid-arm64"; }
m1s_host_architecture() { printf "aarch64"; }
m1s_host_model() { printf "Hardkernel ODROID-M1S"; }
require_root() { return 0; }
sync_repository_to_origin_main() { return 0; }
detect_installed_version() { printf "%s\\n" "$SCRIPT_VERSION"; }
ensure_fullnode_mount_from_state() { : > "$M1S_TEST_MUTATION_MARKER"; }
verify_umbrel_runtime_truth() { : > "$M1S_TEST_TRUTH_MARKER"; return 1; }
main --skip-sync
' 2>&1)"
  main_current_status=$?
  set -e
  assert_eq "0" "$main_current_status" "current-version stopped-runtime bypass currently exits successfully"
  [[ -e "$main_mutation_marker" ]] || fail "current-version stopped-runtime bypass currently reaches mount repair"
  [[ ! -e "$main_truth_marker" ]] || fail "current-version stopped-runtime bypass must currently skip runtime truth"
  assert_contains "No migrations needed" "$main_current_output" "current-version stopped-runtime bypass reports no migrations"
  pass "current-version stopped runtime is characterized before no-migration routing coverage"
fi

if [[ "${M1S_TEST_CURRENT_VERSION_ROUTING:-0}" -eq 1 ]]; then
  run_current_version_main_dispatch_case() {
    local label="$1"
    local current_version="$2"
    local check_only="$3"
    local expected_status="$4"
    local expect_reconcile="$5"
    local expect_mount="$6"
    local expect_newer="$7"
    local output status reconcile_marker mount_marker

    with_test_state
    reconcile_marker="$TEST_TMPDIR/$label-reconcile"
    mount_marker="$TEST_TMPDIR/$label-mount"
    set +e
    output="$(M1S_TEST_CURRENT_VERSION="$current_version" M1S_TEST_CURRENT_RUNTIME_STATE=exited M1S_TEST_RECONCILE_MARKER="$reconcile_marker" M1S_TEST_MOUNT_MARKER="$mount_marker" bash -c '
set -Eeuo pipefail
source scripts/m1s-update-umbrel.sh
m1s_host_os_id() { printf "ubuntu"; }
m1s_host_os_version() { printf "22.04"; }
m1s_host_kernel_release() { printf "5.10.160-odroid-arm64"; }
m1s_host_architecture() { printf "aarch64"; }
m1s_host_model() { printf "Hardkernel ODROID-M1S"; }
require_root() { return 0; }
sync_repository_to_origin_main() { return 0; }
detect_installed_version() { printf "%s\\n" "$M1S_TEST_CURRENT_VERSION"; }
ensure_fullnode_mount_from_state() { : > "$M1S_TEST_MOUNT_MARKER"; }
reconcile_current_version_runtime() {
  [[ "$M1S_TEST_CURRENT_RUNTIME_STATE" == "exited" ]] || return 1
  : > "$M1S_TEST_RECONCILE_MARKER"
}
if [[ "${M1S_TEST_CHECK_ONLY:-0}" -eq 1 ]]; then
  main --check --skip-sync
else
  main --skip-sync
fi
' 2>&1)"
    status=$?
    set -e
    assert_eq "$check_only" "${M1S_TEST_CHECK_ONLY:-0}" "$label receives the requested check mode"
    assert_eq "$expected_status" "$status" "$label exits with the routed result"
    if [[ "$expect_reconcile" == "1" ]]; then
      [[ -e "$reconcile_marker" ]] || fail "$label routes an equal current version into runtime reconciliation"
    else
      [[ ! -e "$reconcile_marker" ]] || fail "$label must not reconcile a newer version"
    fi
    if [[ "$expect_mount" == "1" ]]; then
      [[ -e "$mount_marker" ]] || fail "$label reaches the legacy mount path"
    else
      [[ ! -e "$mount_marker" ]] || fail "$label must not repair mounts before its current-version decision"
    fi
    if [[ "$expect_newer" == "1" ]]; then
      assert_contains "newer than this updater target" "$output" "$label reports the newer installed version"
    fi
  }

  printf '[unit] current-version main routing failing first\n'
  M1S_TEST_CHECK_ONLY=0 run_current_version_main_dispatch_case "equal-stopped-apply" "$SCRIPT_VERSION" 0 0 1 0 0
  M1S_TEST_CHECK_ONLY=1 run_current_version_main_dispatch_case "equal-stopped-check" "$SCRIPT_VERSION" 1 0 1 0 0
  M1S_TEST_CHECK_ONLY=0 run_current_version_main_dispatch_case "newer-apply" "0.5.31" 0 0 0 0 1
  M1S_TEST_CHECK_ONLY=1 run_current_version_main_dispatch_case "newer-check" "0.5.31" 1 0 0 0 1
  pass "current-version main routing distinguishes equal stopped drift from newer installs before mutation"
fi

printf '[unit] invalid installed version blocks main before mutation\n'
with_test_state
main_mutation_marker="$TEST_TMPDIR/main-mutation"
set +e
main_invalid_output="$(M1S_TEST_MUTATION_MARKER="$main_mutation_marker" bash -c '
set -Eeuo pipefail
source scripts/m1s-update-umbrel.sh
m1s_host_os_id() { printf "ubuntu"; }
m1s_host_os_version() { printf "22.04"; }
m1s_host_kernel_release() { printf "5.10.160-odroid-arm64"; }
m1s_host_architecture() { printf "aarch64"; }
m1s_host_model() { printf "Hardkernel ODROID-M1S"; }
require_root() { return 0; }
sync_repository_to_origin_main() { return 0; }
detect_installed_version() { printf "0.5.x\\n"; }
ensure_fullnode_mount_from_state() { : > "$M1S_TEST_MUTATION_MARKER"; }
main --skip-sync
' 2>&1)"
main_invalid_status=$?
set -e
[[ "$main_invalid_status" -ne 0 ]] || fail "main must reject an invalid installed version"
[[ ! -e "$main_mutation_marker" ]] || fail "main must reject an invalid installed version before mount repair"
assert_contains "Invalid installed version format" "$main_invalid_output" "main reports the generalized invalid-version error"
pass "invalid installed versions fail closed before updater mutation"

pass "build_migration_plan covers full, partial, current, and invalid installs"

printf '[unit] running app capture characterization\n'
with_test_state
docker() {
  [[ "$1" == "ps" && "$2" == "--format" ]] || return 1
  printf 'umbrel\nbitcoin\n'
}
load_running_app_containers
assert_eq "bitcoin" "${STOPPED_APP_CONTAINERS[*]}" "running non-Umbrel containers are captured for graceful restart"
unset -f docker
pass "running app capture preserves the public graceful-restart behavior"

printf '[unit] install state transitions\n'
with_test_state
mark_step_started "0.4.4_to_0.4.5"
assert_json_eq "$INSTALL_STATE_FILE" 'data["in_progress_step"]' "0.4.4_to_0.4.5" "started step is recorded"
assert_json_eq "$INSTALL_STATE_FILE" 'data["failed_step"]' "null" "started clears failed step"
assert_json_missing "$INSTALL_STATE_FILE" "version"
mark_step_completed "0.4.4_to_0.4.5" "0.4.5"
assert_json_eq "$INSTALL_STATE_FILE" 'data["applied_steps"]' "0.4.4_to_0.4.5" "completed step is added to applied_steps"
assert_json_eq "$INSTALL_STATE_FILE" 'data["last_completed_version"]' "0.4.5" "completed records internal progress version"
assert_json_missing "$INSTALL_STATE_FILE" "version"
assert_json_missing "$INSTALL_STATE_FILE" "host_version"
state_test_image_id="sha256:state-test-image-id"
original_verified_umbrel_runtime_snapshot="$(declare -f verified_umbrel_runtime_snapshot)"
original_verify_umbrel_runtime_truth="$(declare -f verify_umbrel_runtime_truth)"
verified_umbrel_runtime_snapshot() {
  VERIFIED_UMBREL_RUNTIME_IMAGE="$UMBREL_IMAGE"
  VERIFIED_UMBREL_RUNTIME_IMAGE_ID="$state_test_image_id"
}
verify_umbrel_runtime_truth() {
  VERIFIED_UMBREL_RUNTIME_IMAGE="$UMBREL_IMAGE"
  VERIFIED_UMBREL_RUNTIME_IMAGE_ID="$state_test_image_id"
}
finalize_install_state "0.4.12"
eval "$original_verified_umbrel_runtime_snapshot"
eval "$original_verify_umbrel_runtime_truth"
assert_json_eq "$INSTALL_STATE_FILE" 'data["version"]' "0.4.12" "finalize writes version"
assert_json_eq "$INSTALL_STATE_FILE" 'data["host_version"]' "0.4.12" "finalize writes host_version"
assert_json_eq "$INSTALL_STATE_FILE" 'data["image"]' "$UMBREL_IMAGE" "finalize writes the verified live image ref for every target version"
assert_json_eq "$INSTALL_STATE_FILE" 'data["image_id"]' "$state_test_image_id" "finalize writes the resolved live image ID for every target version"
pass "state transitions do not publish final version before finalize"

printf '[unit] failed state transition\n'
with_test_state
mark_step_started "0.4.4_to_0.4.5"
mark_step_failed "0.4.4_to_0.4.5" "postcheck failed"
assert_json_eq "$INSTALL_STATE_FILE" 'data["in_progress_step"]' "null" "failure clears in_progress_step"
assert_json_eq "$INSTALL_STATE_FILE" 'data["failed_step"]' "0.4.4_to_0.4.5" "failure records failed_step"
assert_json_eq "$INSTALL_STATE_FILE" 'data["last_error"]' "postcheck failed" "failure records last_error"
assert_json_missing "$INSTALL_STATE_FILE" "version"
pass "failure records diagnostic state without final version"

printf '[unit] installed version detection\n'
with_test_state
mkdir -p "$INSTALL_STATE_DIR"
cat > "$INSTALL_STATE_FILE" <<'JSON'
{"host_version":"0.4.4","version":"0.4.3"}
JSON
assert_eq "0.4.4" "$(read_installed_version_from_state)" "host_version has priority over legacy version"
cat > "$INSTALL_STATE_FILE" <<'JSON'
{"applied_steps":["0.4.3_to_0.4.4"]}
JSON
assert_eq "0.4.4" "$(read_installed_version_from_state)" "applied_steps can infer current version when explicit version is missing"
pass "installed version detection supports host_version, version, and applied_steps"

printf '[unit] fullnode fstab self-healing check mode\n'
with_test_state
mkdir -p "$INSTALL_STATE_DIR" "$TEST_TMPDIR/dev"
target_partition="$TEST_TMPDIR/dev/nvme0n1p1"
: > "$target_partition"
cat > "$INSTALL_STATE_FILE" <<JSON
{"host_version":"0.5.17","data_dir":"$DATA_DIR","target_partition":"$target_partition"}
JSON
cat > "$FSTAB_FILE" <<'EOF'
UUID="root" / ext4 defaults 0 0
UUID="boot" /boot ext2 defaults 0 0
EOF
M1S_TEST_ALLOW_NON_BLOCK_TARGET=1
M1S_TEST_TARGET_UUID="target-uuid"
ensure_fullnode_mount_from_state check > "$TEST_TMPDIR/check.out"
grep -q 'missing from /etc/fstab' "$TEST_TMPDIR/check.out" || fail "check mode should report missing fullnode fstab entry"
grep -q "append UUID=target-uuid $DATA_DIR ext4 $FULLNODE_FSTAB_OPTIONS 0 0" "$TEST_TMPDIR/check.out" || fail "check mode should show planned canonical UUID repair"
if grep -q "$DATA_DIR" "$FSTAB_FILE"; then
  fail "check mode must not mutate fstab"
fi
findmnt() { return 0; }
ensure_fullnode_mount_from_state repair > "$TEST_TMPDIR/repair.out"
space_re='[[:space:]]*'
expected_re="UUID=target-uuid${space_re}${DATA_DIR}${space_re}ext4${space_re}${FULLNODE_FSTAB_OPTIONS}${space_re}0${space_re}0"
if ! grep -q "$expected_re" "$FSTAB_FILE"; then
  fail "repair mode should write canonical fullnode fstab options"
fi
unset -f findmnt
cat > "$FSTAB_FILE" <<EOF
UUID=wrong-uuid $DATA_DIR ext4 defaults 0 0
EOF
if ensure_fullnode_mount_from_state check >/dev/null 2>&1; then
  fail "self-heal should refuse a conflicting fullnode fstab source"
fi
pass "fullnode fstab self-healing check and repair modes use canonical options and reject conflicts"

printf '[unit] run_migration_step success and skip\n'
with_test_state
EVENTS=()
precheck_9_0_0_to_9_0_1() { EVENTS+=(pre); }
apply_9_0_0_to_9_0_1() { EVENTS+=(apply); }
postcheck_9_0_0_to_9_0_1() { EVENTS+=(post); }
run_migration_step "9.0.0_to_9.0.1"
assert_eq "pre apply post" "${EVENTS[*]}" "successful step calls pre/apply/post in order"
assert_json_eq "$INSTALL_STATE_FILE" 'data["applied_steps"]' "9.0.0_to_9.0.1" "successful step is marked applied"
assert_json_eq "$INSTALL_STATE_FILE" 'data["last_completed_version"]' "9.0.1" "successful step records last_completed_version"
assert_json_missing "$INSTALL_STATE_FILE" "version"
update_install_state finalized "" "9.0.1" "" "" ""
EVENTS=()
run_migration_step "9.0.0_to_9.0.1"
assert_eq "" "${EVENTS[*]}" "already applied step is skipped without rerunning handlers"
cat > "$INSTALL_STATE_FILE" <<'JSON'
{"version":"9.0.0","host_version":"9.0.0","applied_steps":["9.0.0_to_9.0.1"]}
JSON
TARGET_VERSION="9.0.1"
EVENTS=()
run_migration_step "9.0.0_to_9.0.1"
assert_eq "pre apply post" "${EVENTS[*]}" "recorded unfinalized step replays its recovery handlers"
unset TARGET_VERSION
pass "run_migration_step succeeds, skips finalized steps, and replays unfinalized recovery steps"

printf '[unit] public 0.5.26 history baseline\n'
with_test_state
public_history_step_present=0
for migration in "${MIGRATIONS[@]}"; do
  if [[ "$migration" == "0.5.25_to_0.5.26" ]]; then
    public_history_step_present=1
    break
  fi
done
assert_eq "1" "$public_history_step_present" "public 0.5.26 history step remains registered"

HISTORY_EVENTS=()
MUTATION_EVENTS=()
original_info="$(declare -f info)"
original_install_safe_shutdown="$(declare -f install_umbrel_safe_shutdown)"
original_postcheck_safe_shutdown="$(declare -f postcheck_umbrel_safe_shutdown)"
info() { HISTORY_EVENTS+=("$1"); }
# shellcheck disable=SC2317,SC2329 # Test stub is invoked indirectly through migration dispatch.
install_umbrel_safe_shutdown() { MUTATION_EVENTS+=(safe-shutdown-install); }
# shellcheck disable=SC2317,SC2329 # Test stub is invoked indirectly through migration dispatch.
postcheck_umbrel_safe_shutdown() { MUTATION_EVENTS+=(safe-shutdown-postcheck); }
# shellcheck disable=SC2317,SC2329 # Safety stub guards against unintended host mutation.
systemctl() { MUTATION_EVENTS+=(systemctl); }
# shellcheck disable=SC2317,SC2329 # Safety stub guards against unintended host mutation.
mount() { MUTATION_EVENTS+=(mount); }
# shellcheck disable=SC2317,SC2329 # Safety stub guards against unintended host mutation.
nmcli() { MUTATION_EVENTS+=(nmcli); }

apply_0_5_25_to_0_5_26
assert_eq "0.5.26 restores the existing-device login guidance; no immediate host mutation required." "${HISTORY_EVENTS[*]}" "public 0.5.26 step remains a history-only release"
assert_eq "" "${MUTATION_EVENTS[*]}" "public 0.5.26 step leaves safe shutdown and legacy networking untouched"

eval "$original_info"
eval "$original_install_safe_shutdown"
eval "$original_postcheck_safe_shutdown"
unset -f systemctl mount nmcli
pass "public 0.5.26 history step remains a no-host-mutation baseline"

printf '[unit] v0.5.31 script-only recovery migration baseline\n'
with_test_state
assert_eq "0.5.31" "$SCRIPT_VERSION" "updater targets the v0.5.31 recovery-script release"

build_migration_plan "0.5.26"
assert_eq "0.5.26_to_0.5.27 0.5.27_to_0.5.28 0.5.28_to_0.5.29 0.5.29_to_0.5.30 0.5.30_to_0.5.31" "${PLANNED_MIGRATIONS[*]}" "0.5.26 plans the reliability, mDNS, CSP, and recovery-script transitions"
build_migration_plan "0.5.27"
assert_eq "0.5.27_to_0.5.28 0.5.28_to_0.5.29 0.5.29_to_0.5.30 0.5.30_to_0.5.31" "${PLANNED_MIGRATIONS[*]}" "local 0.5.27 plans host-profile history before mDNS, CSP, and recovery-script transitions"
build_migration_plan "0.5.28"
assert_eq "0.5.28_to_0.5.29 0.5.29_to_0.5.30 0.5.30_to_0.5.31" "${PLANNED_MIGRATIONS[*]}" "local 0.5.28 plans mDNS, CSP, and recovery-script transitions"
build_migration_plan "0.5.29"
assert_eq "0.5.29_to_0.5.30 0.5.30_to_0.5.31" "${PLANNED_MIGRATIONS[*]}" "local 0.5.29 plans the CSP and recovery-script steps"
build_migration_plan "0.5.30"
assert_eq "0.5.30_to_0.5.31" "${PLANNED_MIGRATIONS[*]}" "local 0.5.30 plans only the recovery-script step"

printf '[unit] v0.5.31 check-only migration plan\n'
with_test_state
mkdir -p "$INSTALL_STATE_DIR"
cat > "$INSTALL_STATE_FILE" <<'JSON'
{"version":"0.5.30","host_version":"0.5.30","applied_steps":[]}
JSON
check_mount_mode_file="$TEST_TMPDIR/check-mount-mode"
check_output="$(
  (
    m1s_report_host_support() { :; }
    require_root() { :; }
    sync_repository_to_origin_main() { :; }
    ensure_fullnode_mount_from_state() { printf '%s\n' "$1" > "$check_mount_mode_file"; }
    main --check --skip-sync
  )
)"
assert_contains "  - 0.5.30_to_0.5.31" "$check_output" "0.5.30 check plans only the recovery-script step"
assert_not_contains "0.5.29_to_0.5.30" "$check_output" "0.5.30 check excludes completed earlier migrations"
assert_contains "--check specified; not applying anything." "$check_output" "0.5.30 check reports its no-apply boundary"
assert_eq "check" "$(<"$check_mount_mode_file")" "0.5.30 check uses the read-only mount path"
assert_json_eq "$INSTALL_STATE_FILE" 'data["version"]' "0.5.30" "0.5.30 check leaves the installed version unchanged"
assert_json_eq "$INSTALL_STATE_FILE" 'data["applied_steps"]' "" "0.5.30 check leaves migration history unchanged"
pass "v0.5.31 check-only plan is exactly the recovery-script migration"

SAFE_SHUTDOWN_EVENTS=()
DEFERRED_NETWORK_EVENTS=()
PROFILE_HISTORY_EVENTS=()
SAFE_SHUTDOWN_INSTALL_FAIL=0
original_precheck_common="$(declare -f precheck_common_canonical_install)"
original_info="$(declare -f info)"
original_install_safe_shutdown="$(declare -f install_umbrel_safe_shutdown)"
original_postcheck_safe_shutdown="$(declare -f postcheck_umbrel_safe_shutdown)"
original_system_containers_need_replacement="$(declare -f system_containers_need_replacement)"
original_repair_current_umbrel_runtime="$(declare -f repair_current_umbrel_runtime)"
original_m1s_configure_avahi_mdns="$(declare -f m1s_configure_avahi_mdns)"
original_m1s_avahi_internal_health_check="$(declare -f m1s_avahi_internal_health_check)"
precheck_common_canonical_install() { SAFE_SHUTDOWN_EVENTS+=(data-mount-precheck); }
info() { PROFILE_HISTORY_EVENTS+=("$1"); }
# shellcheck disable=SC2317,SC2329 # Test stub is invoked indirectly through migration dispatch.
install_umbrel_safe_shutdown() {
  SAFE_SHUTDOWN_EVENTS+=(safe-shutdown-install)
  [[ "$SAFE_SHUTDOWN_INSTALL_FAIL" -eq 0 ]]
}
# shellcheck disable=SC2317,SC2329 # Test stub is invoked indirectly through migration dispatch.
postcheck_umbrel_safe_shutdown() { SAFE_SHUTDOWN_EVENTS+=(safe-shutdown-postcheck); }
SYSTEM_CONTAINERS_NEED_REPLACEMENT=0
system_containers_need_replacement() { [[ "$SYSTEM_CONTAINERS_NEED_REPLACEMENT" -eq 1 ]]; }
repair_current_umbrel_runtime() { SAFE_SHUTDOWN_EVENTS+=(runtime-repair); }
# shellcheck disable=SC2317,SC2329 # Safety stub guards against unintended deferred network mutation.
nmcli() { DEFERRED_NETWORK_EVENTS+=(nmcli); }
# shellcheck disable=SC2317,SC2329 # Safety stub guards against unintended deferred network mutation.
systemctl() { DEFERRED_NETWORK_EVENTS+=(systemctl); }
# shellcheck disable=SC2317,SC2329 # Safety stub guards against unintended deferred network mutation.
mount() { DEFERRED_NETWORK_EVENTS+=(mount); }
# shellcheck disable=SC2317,SC2329 # Test stub is invoked indirectly through migration dispatch.
m1s_configure_avahi_mdns() { DEFERRED_NETWORK_EVENTS+=(mdns-configure); }
# shellcheck disable=SC2317,SC2329 # Test stub is invoked indirectly through migration dispatch.
m1s_avahi_internal_health_check() { DEFERRED_NETWORK_EVENTS+=(mdns-health); }

apply_0_5_27_to_0_5_28
assert_eq "0.5.28 reports the validated host profile without blocking other environments; no immediate host mutation required." "${PROFILE_HISTORY_EVENTS[*]}" "0.5.28 history message describes non-blocking profile guidance"
PROFILE_HISTORY_EVENTS=()

apply_0_5_28_to_0_5_29
assert_eq "0.5.29 repairs stale Avahi interface pins without stopping Docker or Umbrel." "${PROFILE_HISTORY_EVENTS[*]}" "0.5.29 migration message scopes the repair to mDNS"
assert_eq "mdns-configure" "${DEFERRED_NETWORK_EVENTS[*]}" "0.5.29 migration delegates mDNS mutation to the shared helper"
PROFILE_HISTORY_EVENTS=()
DEFERRED_NETWORK_EVENTS=()

apply_0_5_29_to_0_5_30
assert_eq "0.5.30 repairs the managed import-map CSP authorization and restarts Umbrel so the web UI loads it." "${PROFILE_HISTORY_EVENTS[*]}" "0.5.30 migration message scopes the repair to the rendered web UI"
assert_eq "safe-shutdown-install" "${SAFE_SHUTDOWN_EVENTS[*]}" "0.5.30 migration reapplies the safe-shutdown installer to repair the live CSP source and restart Umbrel"
SAFE_SHUTDOWN_EVENTS=()
PROFILE_HISTORY_EVENTS=()

SYSTEM_CONTAINERS_NEED_REPLACEMENT=1
apply_0_5_29_to_0_5_30
assert_eq "safe-shutdown-install runtime-repair" "${SAFE_SHUTDOWN_EVENTS[*]}" "0.5.30 converges stale system containers before final runtime publication"
SYSTEM_CONTAINERS_NEED_REPLACEMENT=0
SAFE_SHUTDOWN_EVENTS=()
PROFILE_HISTORY_EVENTS=()

apply_0_5_30_to_0_5_31
assert_eq "0.5.31 updates Bitcoin recovery scripts only; no immediate host mutation required." "${PROFILE_HISTORY_EVENTS[*]}" "0.5.31 migration scopes the release to updated recovery scripts"
assert_eq "" "${SAFE_SHUTDOWN_EVENTS[*]}" "0.5.31 migration does not modify the safe-shutdown runtime"
assert_eq "" "${DEFERRED_NETWORK_EVENTS[*]}" "0.5.31 migration does not modify deferred network ownership"
PROFILE_HISTORY_EVENTS=()

precheck_0_5_26_to_0_5_27
assert_eq "data-mount-precheck" "${SAFE_SHUTDOWN_EVENTS[*]}" "reliability migration fixture precheck stub is exercised before migration dispatch"
SAFE_SHUTDOWN_EVENTS=()

run_migration_step "0.5.26_to_0.5.27"
assert_eq "data-mount-precheck safe-shutdown-install safe-shutdown-postcheck" "${SAFE_SHUTDOWN_EVENTS[*]}" "reliability transition preserves the canonical data-mount precheck and safe-shutdown flow"
assert_eq "" "${DEFERRED_NETWORK_EVENTS[*]}" "reliability transition leaves deferred network ownership untouched"
assert_json_eq "$INSTALL_STATE_FILE" 'data["applied_steps"]' "0.5.26_to_0.5.27" "reliability transition records completion"

reliability_events_before="${SAFE_SHUTDOWN_EVENTS[*]}"
run_migration_step "0.5.26_to_0.5.27"
assert_eq "$reliability_events_before" "${SAFE_SHUTDOWN_EVENTS[*]}" "applied reliability transition skips handlers idempotently"
assert_eq "" "${DEFERRED_NETWORK_EVENTS[*]}" "idempotent reliability replay leaves deferred network ownership untouched"

with_test_state
SAFE_SHUTDOWN_EVENTS=()
DEFERRED_NETWORK_EVENTS=()
SAFE_SHUTDOWN_INSTALL_FAIL=1
if run_migration_step "0.5.26_to_0.5.27"; then
  fail "safe-shutdown install failure must refuse reliability step completion"
fi
assert_eq "data-mount-precheck safe-shutdown-install" "${SAFE_SHUTDOWN_EVENTS[*]}" "safe-shutdown install failure stops before postcheck"
assert_json_eq "$INSTALL_STATE_FILE" 'data["failed_step"]' "0.5.26_to_0.5.27" "safe-shutdown install failure records the reliability step failure"
assert_json_eq "$INSTALL_STATE_FILE" 'data["applied_steps"]' "" "safe-shutdown install failure does not record step completion"

with_test_state
SAFE_SHUTDOWN_EVENTS=()
DEFERRED_NETWORK_EVENTS=()
SAFE_SHUTDOWN_INSTALL_FAIL=0
run_migration_step "0.5.27_to_0.5.28"
assert_eq "data-mount-precheck" "${SAFE_SHUTDOWN_EVENTS[*]}" "host-profile reporting history step keeps the canonical data-mount precheck without host mutation"
assert_eq "" "${DEFERRED_NETWORK_EVENTS[*]}" "host-profile reporting history step leaves deferred network ownership untouched"

with_test_state
SAFE_SHUTDOWN_EVENTS=()
DEFERRED_NETWORK_EVENTS=()
run_migration_step "0.5.28_to_0.5.29"
assert_eq "data-mount-precheck" "${SAFE_SHUTDOWN_EVENTS[*]}" "mDNS repair keeps the canonical data-mount precheck"
assert_eq "mdns-configure mdns-health systemctl" "${DEFERRED_NETWORK_EVENTS[*]}" "mDNS repair configures only Avahi services and runs its postcheck"
assert_json_eq "$INSTALL_STATE_FILE" 'data["applied_steps"]' "0.5.28_to_0.5.29" "mDNS repair step records completion"

with_test_state
SAFE_SHUTDOWN_EVENTS=()
DEFERRED_NETWORK_EVENTS=()
run_migration_step "0.5.29_to_0.5.30"
assert_eq "data-mount-precheck safe-shutdown-install safe-shutdown-postcheck" "${SAFE_SHUTDOWN_EVENTS[*]}" "CSP repair keeps the canonical data-mount precheck and verifies the repaired live UI"
assert_eq "" "${DEFERRED_NETWORK_EVENTS[*]}" "CSP repair does not mutate deferred network ownership"
assert_json_eq "$INSTALL_STATE_FILE" 'data["applied_steps"]' "0.5.29_to_0.5.30" "CSP repair step records completion"

with_test_state
SAFE_SHUTDOWN_EVENTS=()
DEFERRED_NETWORK_EVENTS=()
run_migration_step "0.5.30_to_0.5.31"
assert_eq "data-mount-precheck" "${SAFE_SHUTDOWN_EVENTS[*]}" "recovery-script step keeps the canonical data-mount precheck without host mutation"
assert_eq "" "${DEFERRED_NETWORK_EVENTS[*]}" "recovery-script step does not mutate deferred network ownership"
assert_json_eq "$INSTALL_STATE_FILE" 'data["applied_steps"]' "0.5.30_to_0.5.31" "recovery-script step records completion"

eval "$original_precheck_common"
eval "$original_info"
eval "$original_install_safe_shutdown"
eval "$original_postcheck_safe_shutdown"
eval "$original_system_containers_need_replacement"
eval "$original_repair_current_umbrel_runtime"
eval "$original_m1s_configure_avahi_mdns"
eval "$original_m1s_avahi_internal_health_check"
unset -f nmcli systemctl mount
pass "v0.5.31 migration preserves prior repairs and records the recovery-script update without host mutation"

printf '[unit] run_migration_step failure paths\n'
with_test_state
EVENTS=()
precheck_9_1_0_to_9_1_1() { EVENTS+=(pre); }
apply_9_1_0_to_9_1_1() { EVENTS+=(apply); return 1; }
postcheck_9_1_0_to_9_1_1() { EVENTS+=(post); }
if run_migration_step "9.1.0_to_9.1.1"; then
  fail "apply failure should make run_migration_step fail"
fi
assert_eq "pre apply" "${EVENTS[*]}" "apply failure stops before postcheck"
assert_json_eq "$INSTALL_STATE_FILE" 'data["failed_step"]' "9.1.0_to_9.1.1" "apply failure records failed_step"
assert_json_eq "$INSTALL_STATE_FILE" 'data["last_error"]' "apply failed" "apply failure records last_error"
assert_json_missing "$INSTALL_STATE_FILE" "version"

with_test_state
EVENTS=()
precheck_9_2_0_to_9_2_1() { EVENTS+=(pre); }
apply_9_2_0_to_9_2_1() { EVENTS+=(apply); }
postcheck_9_2_0_to_9_2_1() { EVENTS+=(post); return 1; }
if run_migration_step "9.2.0_to_9.2.1"; then
  fail "postcheck failure should make run_migration_step fail"
fi
assert_eq "pre apply post" "${EVENTS[*]}" "postcheck failure runs all handlers then fails"
assert_json_eq "$INSTALL_STATE_FILE" 'data["failed_step"]' "9.2.0_to_9.2.1" "postcheck failure records failed_step"
assert_json_eq "$INSTALL_STATE_FILE" 'data["last_error"]' "postcheck failed" "postcheck failure records last_error"
assert_json_missing "$INSTALL_STATE_FILE" "version"
pass "run_migration_step records apply and postcheck failures without final version"

printf '[unit] CLI argument parsing\n'
DRY_RUN=0
CHECK_ONLY=0
AUTO_SYNC=1
parse_args --check --dry-run --skip-sync
assert_eq "1" "$CHECK_ONLY" "--check sets CHECK_ONLY"
assert_eq "1" "$DRY_RUN" "--dry-run sets DRY_RUN"
assert_eq "0" "$AUTO_SYNC" "--skip-sync disables repository auto-sync"
pass "parse_args handles check, dry-run, and skip-sync flags"

printf '[unit] updater writes content-hashed 75s shutdown UI asset\n'
with_test_state
FAKE_UI_ROOT="$TEST_TMPDIR/umbreld-ui"
FAKE_UI_ASSET_DIR="$FAKE_UI_ROOT/assets"
FAKE_SERVER_SOURCE="$TEST_TMPDIR/umbreld-server.ts"
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
    M1S_TEST_UMBREL_UI_ROOT="$FAKE_UI_ROOT" M1S_TEST_UMBREL_SERVER_SOURCE="$FAKE_SERVER_SOURCE" "$@"
    return $?
  fi
  return 1
}

reset_shutdown_ui_fixture() {
  rm -rf "$FAKE_UI_ROOT"
  mkdir -p "$FAKE_UI_ASSET_DIR"
  printf '%s\n' \
    'helmet.contentSecurityPolicy({' \
    '  directives: {' \
    "    scriptSrc: this.umbreld.developmentMode ? [\"'self'\", \"'unsafe-inline'\"] : null," \
    '  },' \
    '})' > "$FAKE_SERVER_SOURCE"
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

shutdown_import_map_csp_hash_for() {
  python3 - "$1" "$2" <<'PY'
import base64
import hashlib
import json
import sys

payload = json.dumps({'imports': {sys.argv[1]: sys.argv[2]}}, separators=(',', ':')).encode()
print(base64.b64encode(hashlib.sha256(payload).digest()).decode())
PY
}

assert_shutdown_import_map_csp_hash() {
  local original_ref="$1"
  local generated_ref="$2"
  local label="$3"
  local expected_hash

  expected_hash="$(shutdown_import_map_csp_hash_for "$original_ref" "$generated_ref")"
  assert_contains "scriptSrc: this.umbreld.developmentMode ? [\"'self'\", \"'unsafe-inline'\"] : [\"'self'\", \"'sha256-$expected_hash'\"]," "$(<"$FAKE_SERVER_SOURCE")" "$label must authorize exactly the managed import-map payload"
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
  assert_contains "$canonical_region" "$patched_asset" "$label patched asset should use the 75s status-only branch"
  assert_contains "$memo_suffix" "$patched_asset" "$label patched asset should preserve the React Compiler dependency array"
  assert_not_contains "$source_callback" "$patched_asset" "$label patched asset should remove the upstream error gate"
  assert_not_contains "$public_callback" "$patched_asset" "$label patched asset should remove the 30s status-only branch"
  assert_contains "/assets/$new_asset_name" "$index_text" "$label index must reference the new hashed asset"
  assert_shutdown_import_map_csp_hash "/assets/index-7c0be990.js" "/assets/$new_asset_name" "$label"
  patch_umbrel_shutdown_ui
  assert_eq "$patched_asset" "$(<"$new_asset_path")" "$label canonical rerun must leave hashed asset bytes unchanged"
  assert_eq "$index_text" "$(<"$FAKE_UI_ROOT/index.html")" "$label canonical rerun must leave index unchanged"

  python3 - "$FAKE_SERVER_SOURCE" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
prefix = "scriptSrc: this.umbreld.developmentMode ? [\"'self'\", \"'unsafe-inline'\"] : "
lines = path.read_text(encoding='utf-8').splitlines(keepends=True)
matches = [index for index, line in enumerate(lines) if line.strip().startswith(prefix)]
if len(matches) != 1:
    raise SystemExit('expected exactly one fixture CSP directive')
newline = '\n' if lines[matches[0]].endswith('\n') else ''
indent = lines[matches[0]][:len(lines[matches[0]]) - len(lines[matches[0]].lstrip())]
lines[matches[0]] = f'{indent}{prefix}null,{newline}'
path.write_text(''.join(lines), encoding='utf-8')
PY
  if verify_umbrel_shutdown_ui >/dev/null 2>&1; then
    fail "$label verify must reject a managed import map whose CSP authorization was removed"
  fi
  patch_umbrel_shutdown_ui
  verify_umbrel_shutdown_ui
  assert_shutdown_import_map_csp_hash "/assets/index-7c0be990.js" "/assets/$new_asset_name" "$label existing managed map must restore its CSP authorization"
  assert_eq "$patched_asset" "$(<"$new_asset_path")" "$label CSP repair must not rewrite the generated asset"
  assert_eq "$index_text" "$(<"$FAKE_UI_ROOT/index.html")" "$label CSP repair must not rewrite the managed import map"
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
assert_hashed_shutdown_patch 'public v0.5.26 status-only 30s branch' "$public_region"

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
  assert_contains "$canonical_region" "$patched_asset" "Vite modulepreload fixture must patch the executable module entry"
  assert_contains 'href="/assets/chunk-alpha.js"' "$index_text" "Vite modulepreload fixture must preserve modulepreload hints"
  assert_contains "/assets/$new_asset_name" "$index_text" "Vite modulepreload fixture must retarget only the executable module entry"
  assert_not_contains 'src="/assets/entry-module.js"' "$index_text" "Vite modulepreload fixture must remove the old executable module entry reference"
  assert_contains "{\"imports\":{\"/assets/entry-module.js\":\"/assets/$new_asset_name\"}}" "$index_text" "Vite modulepreload fixture must map old dependent imports to the generated entry"
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
  assert_contains 'href="/assets/entry-module.js"' "$index_text" "Shared-entry modulepreload hint must remain unchanged"
  assert_contains "src=\"/assets/$new_asset_name\"" "$index_text" "Shared-entry executable script must point to the generated asset"
  assert_not_contains 'src="/assets/entry-module.js"' "$index_text" "Shared-entry executable script must not retain the old asset"
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
  assert_contains "$expected_map" "$index_text" "Split-chunk fixture must map the dependent old-entry import to the generated entry"
  assert_contains 'data-m1s-shutdown-ui' "$index_text" "Split-chunk fixture must install one managed import map"
  [[ "$(grep -o 'data-m1s-shutdown-ui' <<<"$index_text" | wc -l)" -eq 1 ]] || fail "Split-chunk fixture must install exactly one managed import map"
  managed_map_offset="$(python3 -c 'import sys; print(sys.stdin.read().find("data-m1s-shutdown-ui"))' <<<"$index_text")"
  modulepreload_offset="$(python3 -c 'import sys; print(sys.stdin.read().find("rel=\"modulepreload\""))' <<<"$index_text")"
  module_script_offset="$(python3 -c 'import sys; print(sys.stdin.read().find("<script type=\"module\""))' <<<"$index_text")"
  [[ "$managed_map_offset" -ge 0 && "$managed_map_offset" -lt "$modulepreload_offset" && "$managed_map_offset" -lt "$module_script_offset" ]] || fail "Split-chunk fixture must insert the import map before modulepreload and module execution"
  [[ "${index_text%%<script type=\"module\"*}" == *'data-m1s-shutdown-ui'* ]] || fail "Split-chunk fixture must insert the import map before module execution"
  assert_contains 'import "./old-entry.js"' "$(<"$FAKE_UI_ASSET_DIR/dependent.js")" "Split-chunk fixture must retain the preloaded dependent static original import"
  assert_contains 'import "./old-entry.js"' "$(<"$FAKE_UI_ASSET_DIR/settings-content.js")" "Split-chunk fixture must retain the dependent Vite static old-entry import"
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
assert_contains "{\"imports\":{\"/assets/index-7c0be990.js\":\"/assets/$canonical_name\"}}" "$canonical_index_after_repair" "canonical repair must map the immutable original entry"
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

unset -f docker
pass "Updater writes a deterministic 75s hashed shutdown UI asset and fails closed"

printf '[unit] updater repository auto-sync\n'
cleanup_test_state
new_auto_sync_test_repo
DRY_RUN=1
AUTO_SYNC=1
sync_repository_to_origin_main --check > "$TEST_TMPDIR/dry-run.out"
assert_eq "" "$(cat "$FAKE_GIT_LOG")" "dry-run should not invoke git"
grep -q 'fetch origin' "$TEST_TMPDIR/dry-run.out" || fail "dry-run should show fetch origin"
grep -q 'reset --hard origin/main' "$TEST_TMPDIR/dry-run.out" || fail "dry-run should show reset to origin/main"

DRY_RUN=0
FAKE_HEAD="same-head"
FAKE_ORIGIN_HEAD="same-head"
: > "$FAKE_GIT_LOG"
sync_repository_to_origin_main --check
if [[ -s "$FAKE_BASH_LOG" ]]; then
  fail "same-head sync should not re-exec the updater"
fi
grep -q -- '-c safe.directory='"$AUTO_SYNC_REPO_ROOT_OVERRIDE" "$FAKE_GIT_LOG" || fail "sync should scope safe.directory to this repo"
grep -q -- 'fetch origin' "$FAKE_GIT_LOG" || fail "sync should fetch origin"
grep -q -- 'reset --hard origin/main' "$FAKE_GIT_LOG" || fail "sync should reset to origin/main"

FAKE_ORIGIN_URL="https://example.com/attacker/repo.git"
: > "$FAKE_GIT_LOG"
if sync_repository_to_origin_main --check 2>/dev/null; then
  fail "sync should reject non-official origin URL"
fi
if grep -q -- 'fetch origin' "$FAKE_GIT_LOG"; then
  fail "sync should reject non-official origin before fetch"
fi

FAKE_ORIGIN_URL="https://github.com/dongguri-jun/odroid-m1s-umbrel-recovery.git"
FAKE_FETCH_FAIL=1
if sync_repository_to_origin_main --check 2>/dev/null; then
  fail "sync should fail when fetch fails"
fi
FAKE_FETCH_FAIL=0
FAKE_ORIGIN_MAIN_MISSING=1
if sync_repository_to_origin_main --check 2>/dev/null; then
  fail "sync should fail when origin/main is missing"
fi
FAKE_ORIGIN_MAIN_MISSING=0

FAKE_HEAD="old-head"
FAKE_ORIGIN_HEAD="new-head"
: > "$FAKE_BASH_LOG"
set +e
/bin/bash -c 'set -Eeuo pipefail; source scripts/m1s-update-umbrel.sh; DRY_RUN=0; AUTO_SYNC=1; sync_repository_to_origin_main --check --dry-run'
reexec_status=$?
set -e
assert_eq "42" "$reexec_status" "changed-head sync should exec the latest updater"
assert_eq "$AUTO_SYNC_REPO_ROOT_OVERRIDE/scripts/m1s-update-umbrel.sh --skip-sync --check --dry-run" "$(cat "$FAKE_BASH_LOG")" "re-exec preserves original arguments after --skip-sync"
pass "repository auto-sync validates origin, scopes safe.directory, handles failures, and re-execs safely"

printf '[unit] legacy Incus cleanup dry-run\n'
cleanup_test_state
TEST_TMPDIR="$(mktemp -d)"
PATH="$TEST_TMPDIR/bin:$PATH"
mkdir -p "$TEST_TMPDIR/bin"
cat > "$TEST_TMPDIR/bin/incus" <<'EOF'
#!/bin/bash
set -Eeuo pipefail
if [[ "$*" == "list --format csv -c n" ]]; then
  printf 'containers_bitcoin\ncontainers_saloon\n'
fi
EOF
cat > "$TEST_TMPDIR/bin/dpkg-query" <<'EOF'
#!/bin/bash
set -Eeuo pipefail
case "${@: -1}" in
  incus|incus-client)
    printf 'ii '
    ;;
  *)
    exit 1
    ;;
esac
EOF
cat > "$TEST_TMPDIR/bin/snap" <<'EOF'
#!/bin/bash
set -Eeuo pipefail
exit 1
EOF
chmod +x "$TEST_TMPDIR/bin/incus" "$TEST_TMPDIR/bin/dpkg-query" "$TEST_TMPDIR/bin/snap"
DRY_RUN=1
incus_cleanup_output="$(cleanup_legacy_incus_lxd_remnants)"
[[ "$incus_cleanup_output" == *'[DRY-RUN] incus stop --force containers_bitcoin'* ]] || fail "legacy Incus cleanup dry-run should stop old Incus containers"
[[ "$incus_cleanup_output" == *'[DRY-RUN] incus delete --force containers_saloon'* ]] || fail "legacy Incus cleanup dry-run should delete old Incus containers"
[[ "$incus_cleanup_output" == *'apt-get -o DPkg::Lock::Timeout=300 purge -y incus incus-client'* ]] || fail "legacy Incus cleanup dry-run should purge only installed Incus apt packages"
DRY_RUN=0
pass "legacy Incus cleanup dry-run shows container deletion and package purge without touching Umbrel data"

fake_candidate_docker_reset() {
  FAKE_DOCKER_LOG=()
  FAKE_PULL_FAIL=0
  FAKE_APP_STOP_STATUS=0
  FAKE_CANDIDATE_RUN_FAIL=0
  FAKE_ROLLBACK_RUN_FAIL=0
  FAKE_ROLLBACK_RECORDS_IMAGE_ARGUMENT=0
  FAKE_CANDIDATE_IMAGE_ID="sha256:candidate-image-id"
  FAKE_CANDIDATE_RUNTIME_IMAGE_ID="$FAKE_CANDIDATE_IMAGE_ID"
  FAKE_DIFFERENT_IMAGE_ID="sha256:different-image-id"
  FAKE_CANDIDATE_AUTH_PRESENT=1
  FAKE_CANDIDATE_TOR_PRESENT=1
  FAKE_CANDIDATE_TOR_IMAGE="ghcr.io/getumbrel/tor:0.4.9.11"
  FAKE_UMBREL_CONTAINER_PRESENT=1
  FAKE_UMBREL_IMAGE_ID="sha256:old-image-id"
  FAKE_UMBREL_IMAGE_REF="dockurr/umbrel:1.7.3@sha256:old-image"
  FAKE_OLD_IMAGE_ID="$FAKE_UMBREL_IMAGE_ID"
  FAKE_OLD_IMAGE_REF="$FAKE_UMBREL_IMAGE_REF"
  FAKE_UMBREL_STATE="running"
  FAKE_UMBREL_DATA_SOURCE="$DATA_DIR"
  FAKE_UMBREL_DOCKER_SOCKET_SOURCE="/var/run/docker.sock"
  FAKE_UMBREL_RESTART_POLICY="always"
  FAKE_RUNTIME_DATA_IDENTITY_READY=1
  FAKE_REPAIR_CONVERGES_SAFE_SHUTDOWN=0
  FAKE_REPAIR_CONVERGES_HTTP=0
  FAKE_HOST_DATA_ALIAS_READY=0
  FAKE_RUN_DATA_SOURCE="$DATA_DIR"
  FAKE_AUTH_ID="old-auth-id"
  FAKE_AUTH_STATE="running"
  FAKE_TOR_PROXY_ID="old-tor-proxy-id"
  FAKE_TOR_PROXY_STATE="running"
  FAKE_TOR_PROXY_IMAGE="ghcr.io/getumbrel/tor:0.4.9.10"
  FAKE_UMBREL_AUTH_ID=""
  FAKE_UMBREL_AUTH_STATE="missing"
  FAKE_UMBREL_TOR_PROXY_ID=""
  FAKE_UMBREL_TOR_PROXY_STATE="missing"
  FAKE_UMBREL_TOR_PROXY_IMAGE=""
  FAKE_BITCOIN_ID="bitcoin-id"
  FAKE_BITCOIN_STATE="running"
}

fake_docker_log() {
  local rendered
  printf -v rendered '%q ' "$@"
  FAKE_DOCKER_LOG+=("${rendered% }")
}

fake_docker_log_text() {
  printf '%s\n' "${FAKE_DOCKER_LOG[@]}"
}

fake_docker_log_index() {
  local expected="$1"
  local index
  for index in "${!FAKE_DOCKER_LOG[@]}"; do
    if [[ "${FAKE_DOCKER_LOG[$index]}" == "$expected" ]]; then
      printf '%s\n' "$index"
      return 0
    fi
  done
  return 1
}

assert_fake_docker_order() {
  local first="$1"
  local second="$2"
  local label="$3"
  local first_index second_index
  first_index="$(fake_docker_log_index "$first")" || fail "$label: missing first command '$first'"
  second_index="$(fake_docker_log_index "$second")" || fail "$label: missing second command '$second'"
  [[ "$first_index" -lt "$second_index" ]] || fail "$label: '$first' did not precede '$second'"
}

fake_docker_container_id() {
  case "$1" in
    umbrel) printf '%s\n' "$FAKE_UMBREL_IMAGE_ID" ;;
    auth) printf '%s\n' "$FAKE_AUTH_ID" ;;
    tor_proxy) printf '%s\n' "$FAKE_TOR_PROXY_ID" ;;
    umbrel_auth) printf '%s\n' "$FAKE_UMBREL_AUTH_ID" ;;
    umbrel_tor_proxy) printf '%s\n' "$FAKE_UMBREL_TOR_PROXY_ID" ;;
    bitcoin) printf '%s\n' "$FAKE_BITCOIN_ID" ;;
    *) return 1 ;;
  esac
}

fake_docker_container_present() {
  case "$1" in
    umbrel) [[ "$FAKE_UMBREL_CONTAINER_PRESENT" -eq 1 ]] ;;
    auth) [[ -n "$FAKE_AUTH_ID" ]] ;;
    tor_proxy) [[ -n "$FAKE_TOR_PROXY_ID" ]] ;;
    umbrel_auth) [[ -n "$FAKE_UMBREL_AUTH_ID" ]] ;;
    umbrel_tor_proxy) [[ -n "$FAKE_UMBREL_TOR_PROXY_ID" ]] ;;
    bitcoin) [[ -n "$FAKE_BITCOIN_ID" ]] ;;
    *) return 1 ;;
  esac
}

fake_docker_container_state() {
  case "$1" in
    umbrel) printf '%s\n' "$FAKE_UMBREL_STATE" ;;
    auth) printf '%s\n' "$FAKE_AUTH_STATE" ;;
    tor_proxy) printf '%s\n' "$FAKE_TOR_PROXY_STATE" ;;
    umbrel_auth) printf '%s\n' "$FAKE_UMBREL_AUTH_STATE" ;;
    umbrel_tor_proxy) printf '%s\n' "$FAKE_UMBREL_TOR_PROXY_STATE" ;;
    bitcoin) printf '%s\n' "$FAKE_BITCOIN_STATE" ;;
    *) return 1 ;;
  esac
}

fake_docker_inspect() {
  local format=""
  local container=""
  local argument
  local next_is_format=0
  for argument in "$@"; do
    if [[ "$next_is_format" -eq 1 ]]; then
      format="$argument"
      next_is_format=0
      continue
    fi
    case "$argument" in
      --format)
        next_is_format=1
        ;;
      --format=*)
        format="${argument#--format=}"
        ;;
      *)
        container="$argument"
        ;;
    esac
  done

  [[ -n "$container" ]] || return 1
  fake_docker_container_present "$container" || return 1

  case "$format" in
    *'.State.Status'*) fake_docker_container_state "$container" ;;
    *'.Config.Image'*)
      case "$container" in
        umbrel) printf '%s\n' "$FAKE_UMBREL_IMAGE_REF" ;;
        tor_proxy) printf '%s\n' "$FAKE_TOR_PROXY_IMAGE" ;;
        umbrel_tor_proxy) printf '%s\n' "$FAKE_UMBREL_TOR_PROXY_IMAGE" ;;
        auth) printf '%s\n' "ghcr.io/getumbrel/auth:current" ;;
        umbrel_auth) printf '%s\n' "ghcr.io/getumbrel/auth:current" ;;
      esac
      ;;
    *'.HostConfig.RestartPolicy.Name'*) printf '%s\n' "$FAKE_UMBREL_RESTART_POLICY" ;;
    *'.Mounts'*)
      if [[ "$format" == *'/data'* ]]; then
        printf '%s\n' "$FAKE_UMBREL_DATA_SOURCE"
      elif [[ "$format" == *'/var/run/docker.sock'* ]]; then
        printf '%s\n' "$FAKE_UMBREL_DOCKER_SOCKET_SOURCE"
      fi
      ;;
    *'.Image'*) fake_docker_container_id "$container" ;;
    *'.Id'*) fake_docker_container_id "$container" ;;
    '') return 0 ;;
    *) return 1 ;;
  esac
}

docker() {
  fake_docker_log "$@"
  case "$1" in
    ps)
      [[ "$FAKE_UMBREL_CONTAINER_PRESENT" -eq 1 && "$FAKE_UMBREL_STATE" == "running" ]] && printf 'umbrel\n'
      [[ "$FAKE_AUTH_STATE" == "running" && -n "$FAKE_AUTH_ID" ]] && printf 'auth\n'
      [[ "$FAKE_TOR_PROXY_STATE" == "running" && -n "$FAKE_TOR_PROXY_ID" ]] && printf 'tor_proxy\n'
      [[ "$FAKE_UMBREL_AUTH_STATE" == "running" && -n "$FAKE_UMBREL_AUTH_ID" ]] && printf 'umbrel_auth\n'
      [[ "$FAKE_UMBREL_TOR_PROXY_STATE" == "running" && -n "$FAKE_UMBREL_TOR_PROXY_ID" ]] && printf 'umbrel_tor_proxy\n'
      [[ "$FAKE_BITCOIN_STATE" == "running" ]] && printf 'bitcoin\n'
      ;;
    pull)
      [[ "$FAKE_PULL_FAIL" -eq 0 ]]
      ;;
    image)
      [[ "$2" == "inspect" ]] || return 1
      case "$3" in
        "$UMBREL_IMAGE"|"$FAKE_CANDIDATE_IMAGE_ID") printf '%s\n' "$FAKE_CANDIDATE_IMAGE_ID" ;;
        "$FAKE_DIFFERENT_IMAGE_ID") printf '%s\n' "$FAKE_DIFFERENT_IMAGE_ID" ;;
        *) return 1 ;;
      esac
      ;;
    inspect)
      fake_docker_inspect "${@:2}"
      ;;
    container)
      [[ "$2" == "inspect" ]] || return 1
      fake_docker_inspect "${@:3}"
      ;;
    stop)
      local argument
      for argument in "${@:2}"; do
        case "$argument" in
          --timeout|"$APP_STOP_TIMEOUT_SECONDS") ;;
          umbrel) FAKE_UMBREL_STATE="exited" ;;
          auth) FAKE_AUTH_STATE="exited" ;;
          tor_proxy) FAKE_TOR_PROXY_STATE="exited" ;;
          umbrel_auth) FAKE_UMBREL_AUTH_STATE="exited" ;;
          umbrel_tor_proxy) FAKE_UMBREL_TOR_PROXY_STATE="exited" ;;
          bitcoin) FAKE_BITCOIN_STATE="exited" ;;
          *) return 1 ;;
        esac
      done
      [[ "$FAKE_APP_STOP_STATUS" -eq 0 ]] || return "$FAKE_APP_STOP_STATUS"
      ;;
    rm)
      local argument
      for argument in "${@:2}"; do
        case "$argument" in
          -f) ;;
          umbrel)
            FAKE_UMBREL_CONTAINER_PRESENT=0
            FAKE_UMBREL_IMAGE_ID=""
            ;;
          auth) FAKE_AUTH_ID="" ;;
          tor_proxy) FAKE_TOR_PROXY_ID="" ;;
          umbrel_auth) FAKE_UMBREL_AUTH_ID="" ;;
          umbrel_tor_proxy) FAKE_UMBREL_TOR_PROXY_ID="" ;;
          *) return 1 ;;
        esac
      done
      ;;
    run)
      local image_ref="${!#}"
      if [[ "$image_ref" == "$UMBREL_IMAGE" ]]; then
        [[ "$FAKE_CANDIDATE_RUN_FAIL" -eq 0 ]] || return 1
        FAKE_UMBREL_CONTAINER_PRESENT=1
        FAKE_UMBREL_IMAGE_ID="$FAKE_CANDIDATE_RUNTIME_IMAGE_ID"
        FAKE_UMBREL_IMAGE_REF="$UMBREL_IMAGE"
        FAKE_UMBREL_STATE="running"
        FAKE_UMBREL_DATA_SOURCE="$FAKE_RUN_DATA_SOURCE"
        FAKE_UMBREL_RESTART_POLICY="always"
        if [[ "$FAKE_CANDIDATE_AUTH_PRESENT" -eq 1 ]]; then
          FAKE_UMBREL_AUTH_ID="new-umbrel-auth-id"
          FAKE_UMBREL_AUTH_STATE="running"
        fi
        if [[ "$FAKE_CANDIDATE_TOR_PRESENT" -eq 1 ]]; then
          FAKE_UMBREL_TOR_PROXY_ID="new-umbrel-tor-proxy-id"
          FAKE_UMBREL_TOR_PROXY_STATE="running"
          FAKE_UMBREL_TOR_PROXY_IMAGE="$FAKE_CANDIDATE_TOR_IMAGE"
        fi
        printf 'new-umbrel-id\n'
      else
        [[ "$FAKE_ROLLBACK_RUN_FAIL" -eq 0 ]] || return 1
        FAKE_UMBREL_CONTAINER_PRESENT=1
        FAKE_UMBREL_IMAGE_ID="$image_ref"
        if [[ "$FAKE_ROLLBACK_RECORDS_IMAGE_ARGUMENT" -eq 1 ]]; then
          FAKE_UMBREL_IMAGE_REF="$image_ref"
        else
          FAKE_UMBREL_IMAGE_REF="$FAKE_OLD_IMAGE_REF"
        fi
        FAKE_UMBREL_STATE="running"
        FAKE_UMBREL_DATA_SOURCE="$DATA_DIR"
        FAKE_AUTH_ID="rollback-auth-id"
        FAKE_AUTH_STATE="running"
        FAKE_TOR_PROXY_ID="rollback-tor-proxy-id"
        FAKE_TOR_PROXY_STATE="running"
        FAKE_TOR_PROXY_IMAGE="ghcr.io/getumbrel/tor:0.4.9.10"
        FAKE_UMBREL_AUTH_ID=""
        FAKE_UMBREL_AUTH_STATE="missing"
        FAKE_UMBREL_TOR_PROXY_ID=""
        FAKE_UMBREL_TOR_PROXY_STATE="missing"
        FAKE_UMBREL_TOR_PROXY_IMAGE=""
        printf 'rollback-umbrel-id\n'
      fi
      ;;
    start)
      [[ "$2" == "bitcoin" ]] || return 1
      FAKE_BITCOIN_STATE="running"
      ;;
    *) return 1 ;;
  esac
}

printf '[unit] Dockur 1.7.4 canonical system-container contract\n'
with_test_state

fake_candidate_docker_reset
FAKE_AUTH_ID=""
FAKE_AUTH_STATE="missing"
FAKE_TOR_PROXY_ID=""
FAKE_TOR_PROXY_STATE="missing"
FAKE_UMBREL_AUTH_ID="new-umbrel-auth-id"
FAKE_UMBREL_AUTH_STATE="running"
FAKE_UMBREL_TOR_PROXY_ID="new-umbrel-tor-proxy-id"
FAKE_UMBREL_TOR_PROXY_STATE="running"
FAKE_UMBREL_TOR_PROXY_IMAGE="ghcr.io/getumbrel/tor:0.4.9.11@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
if ! candidate_system_containers_ready "old-auth-id" "old-tor-proxy-id"; then
  fail "Dockur 1.7.4 canonical umbrel_auth and umbrel_tor_proxy with a valid pinned Tor digest must satisfy candidate pre-health"
fi

if ! is_expected_tor_proxy_image "$TOR_PROXY_IMAGE"; then
  fail "tag-only Tor image must satisfy the strict candidate image contract"
fi
if ! is_expected_tor_proxy_image "$FAKE_UMBREL_TOR_PROXY_IMAGE"; then
  fail "digest-pinned Tor image with exactly 64 lowercase hexadecimal characters must satisfy the strict candidate image contract"
fi
for invalid_tor_image in \
  "ghcr.io/other/tor:0.4.9.11" \
  "ghcr.io/getumbrel/tor:0.4.9.10" \
  "ghcr.io/getumbrel/tor:0.4.9.11@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" \
  "ghcr.io/getumbrel/tor:0.4.9.11@sha256:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA" \
  "ghcr.io/getumbrel/tor:0.4.9.11@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa:extra"; do
  if is_expected_tor_proxy_image "$invalid_tor_image"; then
    fail "strict Tor image contract must reject $invalid_tor_image"
  fi
done

fake_candidate_docker_reset
FAKE_UMBREL_AUTH_ID="current-umbrel-auth-id"
FAKE_UMBREL_AUTH_STATE="running"
FAKE_UMBREL_TOR_PROXY_ID="current-umbrel-tor-proxy-id"
FAKE_UMBREL_TOR_PROXY_STATE="running"
FAKE_UMBREL_TOR_PROXY_IMAGE="$TOR_PROXY_IMAGE"
if ! system_containers_need_replacement; then
  fail "healthy canonical containers plus stale legacy auth and tor_proxy must require replacement"
fi

FAKE_AUTH_ID=""
FAKE_AUTH_STATE="missing"
FAKE_TOR_PROXY_ID=""
FAKE_TOR_PROXY_STATE="missing"
if system_containers_need_replacement; then
  fail "healthy canonical-only containers must be treated as current"
fi

fake_candidate_docker_reset
if ! system_containers_need_replacement; then
  fail "a stale legacy-only stack must require replacement because canonical 1.7.4 containers are absent"
fi
pass "canonical candidates require new canonical IDs and accept only the exact Tor repository, tag, and optional digest"

printf '[unit] Dockur candidate lifecycle\n'
with_test_state
assert_fullnode_data_mount_safe() { return 0; }
host_data_alias_ready() { return 1; }

fake_candidate_docker_reset
assert_eq "dockurr/umbrel:1.7.4@sha256:e00c07a838ce3b50641a0a984abe155a7223abacab3426a55409edf21b6e0124" "$UMBREL_IMAGE" "candidate uses the exact Dockur Umbrel 1.7.4 arm64 ref"
load_running_app_containers
assert_eq "bitcoin" "${STOPPED_APP_CONTAINERS[*]}" "all known legacy and canonical system containers are excluded from the ordinary app restart state"
refresh_umbrel_system_container
candidate_log="$(fake_docker_log_text)"
assert_fake_docker_order "pull $UMBREL_IMAGE" "stop --timeout $APP_STOP_TIMEOUT_SECONDS bitcoin" "candidate image pulls before ordinary app stop"
assert_fake_docker_order "stop --timeout $APP_STOP_TIMEOUT_SECONDS bitcoin" "stop auth" "ordinary apps stop before Umbrel-owned system containers"
assert_fake_docker_order "stop auth" "stop umbrel" "system containers stop before the top-level container"
assert_contains "run -d --name umbrel --restart always -p 80:80 -v $DATA_DIR:/data -v /var/run/docker.sock:/var/run/docker.sock --stop-timeout 60 --pid=host --privileged $UMBREL_IMAGE" "$candidate_log" "candidate preserves the original mount, restart, and security options"
assert_contains "start bitcoin" "$candidate_log" "legacy refresh restores ordinary apps after candidate pre-health completes"
assert_eq "new-umbrel-auth-id" "$FAKE_UMBREL_AUTH_ID" "candidate recreates canonical umbrel_auth with a new ID"
assert_eq "new-umbrel-tor-proxy-id" "$FAKE_UMBREL_TOR_PROXY_ID" "candidate recreates canonical umbrel_tor_proxy with a new ID"
assert_eq "ghcr.io/getumbrel/tor:0.4.9.11" "$FAKE_UMBREL_TOR_PROXY_IMAGE" "candidate converges the expected Tor repository and tag"
assert_eq "0" "$UMBREL_TRANSACTION_ACTIVE" "legacy refresh clears its transaction context after success"

fake_candidate_docker_reset
FAKE_PULL_FAIL=1
if refresh_umbrel_system_container; then
  fail "pull failure must make the candidate lifecycle fail"
fi
candidate_log="$(fake_docker_log_text)"
assert_contains "pull $UMBREL_IMAGE" "$candidate_log" "pull-failure scenario attempted the exact candidate"
assert_not_contains "stop " "$candidate_log" "pull failure does not stop any container"
assert_not_contains "rm " "$candidate_log" "pull failure does not remove any container"

fake_candidate_docker_reset
FAKE_UMBREL_IMAGE_ID="$FAKE_CANDIDATE_IMAGE_ID"
FAKE_UMBREL_IMAGE_REF="$UMBREL_IMAGE"
refresh_umbrel_system_container
candidate_log="$(fake_docker_log_text)"
assert_contains "rm tor_proxy" "$candidate_log" "same top-level target replaces a stale tor_proxy"
assert_eq "new-umbrel-tor-proxy-id" "$FAKE_UMBREL_TOR_PROXY_ID" "same target converges a canonical tor proxy"

fake_candidate_docker_reset
FAKE_UMBREL_IMAGE_ID="$FAKE_CANDIDATE_IMAGE_ID"
FAKE_UMBREL_IMAGE_REF="$UMBREL_IMAGE"
FAKE_UMBREL_TOR_PROXY_ID=""
FAKE_UMBREL_TOR_PROXY_STATE="missing"
refresh_umbrel_system_container
assert_eq "new-umbrel-tor-proxy-id" "$FAKE_UMBREL_TOR_PROXY_ID" "same target converges a missing canonical tor proxy"

with_test_state
fake_candidate_docker_reset
FAKE_UMBREL_IMAGE_ID="$FAKE_CANDIDATE_IMAGE_ID"
FAKE_UMBREL_IMAGE_REF="$UMBREL_IMAGE"
FAKE_UMBREL_AUTH_ID="current-umbrel-auth-id"
FAKE_UMBREL_AUTH_STATE="running"
FAKE_UMBREL_TOR_PROXY_ID="current-umbrel-tor-proxy-id"
FAKE_UMBREL_TOR_PROXY_STATE="running"
FAKE_UMBREL_TOR_PROXY_IMAGE="$TOR_PROXY_IMAGE"
refresh_umbrel_system_container
candidate_log="$(fake_docker_log_text)"
assert_contains "rm auth" "$candidate_log" "mixed state removes legacy auth"
assert_contains "rm tor_proxy" "$candidate_log" "mixed state removes legacy tor_proxy"
assert_contains "rm umbrel_auth" "$candidate_log" "mixed state removes canonical auth before replacement"
assert_contains "rm umbrel_tor_proxy" "$candidate_log" "mixed state removes canonical Tor before replacement"
assert_eq "" "$FAKE_AUTH_ID" "mixed state leaves no legacy auth container"
assert_eq "" "$FAKE_TOR_PROXY_ID" "mixed state leaves no legacy tor_proxy container"
assert_eq "new-umbrel-auth-id" "$FAKE_UMBREL_AUTH_ID" "mixed state recreates canonical auth"
assert_eq "new-umbrel-tor-proxy-id" "$FAKE_UMBREL_TOR_PROXY_ID" "mixed state recreates canonical Tor"

fake_candidate_docker_reset
FAKE_RUN_DATA_SOURCE="/wrong-data-source"
CANDIDATE_READINESS_ATTEMPTS=1
if refresh_umbrel_system_container; then
  fail "candidate pre-health must reject a top-level container with the wrong /data mount"
fi
assert_eq "0" "$APP_CONTAINERS_STOPPED" "legacy refresh restores ordinary apps when candidate pre-health fails"
assert_eq "0" "$UMBREL_TRANSACTION_ACTIVE" "legacy refresh clears its transaction context after failure"
CANDIDATE_READINESS_ATTEMPTS=30
pass "candidate lifecycle separates apps, pulls before mutation, and converges system containers"

fake_transaction_hooks() {
  assert_fullnode_data_mount_safe() {
    [[ "$FAKE_POSTCHECK_MOUNT_FAILURE" -eq 0 ]] \
      && [[ "$FAKE_RUNTIME_DATA_IDENTITY_READY" -eq 1 ]] \
      && [[ "$FAKE_UMBREL_DOCKER_SOCKET_SOURCE" == "/var/run/docker.sock" ]] \
      || return 1
    case "$FAKE_UMBREL_DATA_SOURCE" in
      "$DATA_DIR") return 0 ;;
      "$HOST_DATA_ALIAS") [[ "$FAKE_HOST_DATA_ALIAS_READY" -eq 1 ]] ;;
      *) return 1 ;;
    esac
  }
  host_data_alias_ready() { [[ "$FAKE_HOST_DATA_ALIAS_READY" -eq 1 ]]; }
  candidate_system_containers_ready() {
    if [[ "$FAKE_POST_SAFE_SHUTDOWN_SYSTEM_ACTIVE" -eq 1 ]]; then
      ((FAKE_POST_SAFE_SHUTDOWN_SYSTEM_READINESS_CALLS += 1))
      if [[ "$FAKE_POST_SAFE_SHUTDOWN_SYSTEM_MODE" == "delayed" ]] \
        && [[ "$FAKE_POST_SAFE_SHUTDOWN_SYSTEM_READINESS_CALLS" -gt "$FAKE_POST_SAFE_SHUTDOWN_SYSTEM_DELAY" ]]; then
        FAKE_UMBREL_AUTH_ID="new-umbrel-auth-id"
        FAKE_UMBREL_AUTH_STATE="running"
        FAKE_UMBREL_TOR_PROXY_ID="new-umbrel-tor-proxy-id"
        FAKE_UMBREL_TOR_PROXY_STATE="running"
        FAKE_UMBREL_TOR_PROXY_IMAGE="$TOR_PROXY_IMAGE"
      fi
    fi

    [[ -n "$FAKE_UMBREL_AUTH_ID" && -n "$FAKE_UMBREL_TOR_PROXY_ID" ]] \
      && [[ "$FAKE_UMBREL_AUTH_STATE" == "running" && "$FAKE_UMBREL_TOR_PROXY_STATE" == "running" ]] \
      && [[ -z "$1" || "$FAKE_UMBREL_AUTH_ID" != "$1" ]] \
      && [[ -z "$2" || "$FAKE_UMBREL_TOR_PROXY_ID" != "$2" ]] \
      && is_expected_tor_proxy_image "$FAKE_UMBREL_TOR_PROXY_IMAGE"
  }
  sleep() { ((FAKE_SLEEP_CALLS += 1)); }
  # shellcheck disable=SC2329 # Invoked indirectly by repair_current_umbrel_runtime.
  install_umbrel_safe_shutdown() {
    [[ "$FAKE_SAFE_SHUTDOWN_APPLY_FAIL" -eq 0 ]] || return 1
    if [[ "$FAKE_REPAIR_CONVERGES_SAFE_SHUTDOWN" -eq 1 ]]; then
      FAKE_SAFE_SHUTDOWN_COMPONENT="canonical"
    fi
    if [[ "$FAKE_REPAIR_CONVERGES_HTTP" -eq 1 ]]; then
      FAKE_HTTP_READY=1
    fi
    case "$FAKE_POSTCHECK_MUTATION" in
      wrong_top_image) FAKE_UMBREL_IMAGE_ID="sha256:wrong-image-id" ;;
      missing_auth) FAKE_UMBREL_AUTH_ID="" ;;
      wrong_tor) FAKE_UMBREL_TOR_PROXY_IMAGE="ghcr.io/getumbrel/tor:wrong" ;;
      mount_safety) FAKE_POSTCHECK_MOUNT_FAILURE=1 ;;
      delayed_system_readiness)
        FAKE_POST_SAFE_SHUTDOWN_SYSTEM_ACTIVE=1
        FAKE_UMBREL_AUTH_ID=""
        FAKE_UMBREL_AUTH_STATE="missing"
        FAKE_UMBREL_TOR_PROXY_ID=""
        FAKE_UMBREL_TOR_PROXY_STATE="missing"
        FAKE_UMBREL_TOR_PROXY_IMAGE=""
        ;;
      permanent_missing_system_readiness)
        FAKE_POST_SAFE_SHUTDOWN_SYSTEM_ACTIVE=1
        FAKE_UMBREL_AUTH_ID=""
        FAKE_UMBREL_AUTH_STATE="missing"
        FAKE_UMBREL_TOR_PROXY_ID=""
        FAKE_UMBREL_TOR_PROXY_STATE="missing"
        FAKE_UMBREL_TOR_PROXY_IMAGE=""
        ;;
      permanent_wrong_tor_readiness)
        FAKE_POST_SAFE_SHUTDOWN_SYSTEM_ACTIVE=1
        FAKE_UMBREL_TOR_PROXY_IMAGE="ghcr.io/getumbrel/tor:wrong"
        ;;
      "") ;;
      *) return 1 ;;
    esac
  }
  # shellcheck disable=SC2329 # Invoked indirectly by verify_umbrel_runtime_truth.
  postcheck_umbrel_safe_shutdown() {
    [[ "$FAKE_SAFE_SHUTDOWN_POSTCHECK_FAIL" -eq 0 && "$FAKE_SAFE_SHUTDOWN_COMPONENT" == "canonical" ]]
  }
  wait_for_umbrel_http() { [[ "$FAKE_HTTP_READY" -eq 1 ]]; }
}

prepare_transaction_case() {
  with_test_state
  mkdir -p "$INSTALL_STATE_DIR"
  cat > "$INSTALL_STATE_FILE" <<'JSON'
{"host_version":"0.5.24","version":"0.5.24","image":"dockurr/umbrel:1.7.3@sha256:old-image","image_id":"sha256:old-image-id","applied_steps":[]}
JSON
  fake_candidate_docker_reset
  FAKE_SAFE_SHUTDOWN_APPLY_FAIL=0
  FAKE_SAFE_SHUTDOWN_POSTCHECK_FAIL=0
  FAKE_SAFE_SHUTDOWN_COMPONENT="canonical"
  FAKE_HTTP_READY=1
  FAKE_POSTCHECK_MUTATION=""
  FAKE_POSTCHECK_MOUNT_FAILURE=0
  FAKE_POST_SAFE_SHUTDOWN_SYSTEM_ACTIVE=0
  FAKE_POST_SAFE_SHUTDOWN_SYSTEM_MODE=""
  FAKE_POST_SAFE_SHUTDOWN_SYSTEM_DELAY=0
  FAKE_POST_SAFE_SHUTDOWN_SYSTEM_READINESS_CALLS=0
  FAKE_SLEEP_CALLS=0
  FINALIZATION_PUBLICATION_CALLS=0
  CANDIDATE_READINESS_ATTEMPTS=1
}

assert_transaction_rolled_back() {
  local label="$1"
  local candidate_log
  candidate_log="$(fake_docker_log_text)"
  assert_contains "run -d --name umbrel --restart always -p 80:80 -v $DATA_DIR:/data -v /var/run/docker.sock:/var/run/docker.sock --stop-timeout 60 --pid=host --privileged $FAKE_OLD_IMAGE_ID" "$candidate_log" "$label restores the old top-level image"
  assert_contains "rm -f umbrel_auth" "$candidate_log" "$label removes canonical auth leftovers before recreating the legacy stack"
  assert_contains "rm -f umbrel_tor_proxy" "$candidate_log" "$label removes canonical Tor leftovers before recreating the legacy stack"
  assert_contains "start bitcoin" "$candidate_log" "$label restarts the ordinary app"
  assert_eq "$FAKE_OLD_IMAGE_ID" "$FAKE_UMBREL_IMAGE_ID" "$label leaves the old image live"
  assert_eq "rollback-auth-id" "$FAKE_AUTH_ID" "$label restores the legacy auth container"
  assert_eq "rollback-tor-proxy-id" "$FAKE_TOR_PROXY_ID" "$label restores the legacy Tor container"
  assert_json_eq "$INSTALL_STATE_FILE" 'data["image"]' "$FAKE_OLD_IMAGE_REF" "$label preserves the live old image in install state"
  assert_json_eq "$INSTALL_STATE_FILE" 'data["image_id"]' "$FAKE_OLD_IMAGE_ID" "$label preserves the live old image ID in install state"
  assert_json_missing "$INSTALL_STATE_FILE" "target_image"
  assert_json_eq "$INSTALL_STATE_FILE" 'data["last_attempted_image"]' "$UMBREL_IMAGE" "$label records the exact attempted target"
}

printf '[unit] 0.5.25 transaction and runtime-truth state\n'
fake_transaction_hooks
assert_eq "0.5.24_to_0.5.25" "${MIGRATIONS[$((${#MIGRATIONS[@]} - 7))]}" "0.5.25 transaction remains before the 0.5.26 history, reliability, host-profile, mDNS, CSP, and recovery-script steps"

printf '[unit] 0.5.25 finalization baseline characterization\n'
prepare_transaction_case
run_migration_step "0.5.24_to_0.5.25"
finalize_install_state "0.5.25"
assert_json_eq "$INSTALL_STATE_FILE" 'data["version"]' "0.5.25" "direct 0.5.25 finalization publishes the target version only after runtime verification"
assert_json_eq "$INSTALL_STATE_FILE" 'data["host_version"]' "0.5.25" "direct 0.5.25 finalization publishes the target host version only after runtime verification"
assert_json_eq "$INSTALL_STATE_FILE" 'data["image"]' "$UMBREL_IMAGE" "direct 0.5.25 finalization writes the live pinned image ref"
assert_json_eq "$INSTALL_STATE_FILE" 'data["image_id"]' "$FAKE_CANDIDATE_IMAGE_ID" "direct 0.5.25 finalization writes the resolved live image ID"

prepare_transaction_case
FAKE_SAFE_SHUTDOWN_APPLY_FAIL=1
if run_migration_step "0.5.24_to_0.5.25"; then
  fail "baseline failed transaction must not complete"
fi
assert_json_eq "$INSTALL_STATE_FILE" 'data["version"]' "0.5.24" "failed transaction does not publish the target version"
assert_json_eq "$INSTALL_STATE_FILE" 'data["host_version"]' "0.5.24" "failed transaction does not publish the target host version"
assert_json_eq "$INSTALL_STATE_FILE" 'data["image"]' "$FAKE_OLD_IMAGE_REF" "failed transaction records the actual rollback image ref"
assert_json_eq "$INSTALL_STATE_FILE" 'data["image_id"]' "$FAKE_OLD_IMAGE_ID" "failed transaction records the actual rollback image ID"
assert_json_eq "$INSTALL_STATE_FILE" 'data["last_attempted_image"]' "$UMBREL_IMAGE" "failed transaction records the attempted target image"
assert_json_missing "$INSTALL_STATE_FILE" "target_image"
pass "0.5.25 baseline finalization and rollback metadata are characterized"

if [[ "${M1S_TEST_CHARACTERIZE_IMAGE_ONLY:-0}" -eq 1 ]]; then
  printf '[unit] image-only finalization false-success baseline characterization\n'
  prepare_transaction_case
  FAKE_UMBREL_IMAGE_REF="$UMBREL_IMAGE"
  FAKE_UMBREL_IMAGE_ID="$FAKE_CANDIDATE_IMAGE_ID"
  FAKE_UMBREL_STATE="exited"
  finalize_install_state "0.5.31"
  assert_json_eq "$INSTALL_STATE_FILE" 'data["version"]' "0.5.31" "image-only finalization currently publishes an image-correct stopped runtime"
  assert_json_eq "$INSTALL_STATE_FILE" 'data["image"]' "$UMBREL_IMAGE" "image-only finalization currently records the image-correct stopped runtime"
  pass "image-only finalization false-success path is characterized before runtime-truth coverage"
fi

assert_finalization_failure_preserves_state() {
  local label="$1"
  local expected_refusal="$2"
  local expected_predicate="$3"
  local before_state="$TEST_TMPDIR/$label-before.json"
  local finalization_output="$TEST_TMPDIR/$label-finalization.out"

  cp "$INSTALL_STATE_FILE" "$before_state"
  if finalize_install_state "0.5.31" >"$finalization_output" 2>&1; then
    fail "$label must reject finalization"
  fi
  cmp -s "$before_state" "$INSTALL_STATE_FILE" || fail "$label must leave install state byte-for-byte unchanged"
  assert_json_eq "$INSTALL_STATE_FILE" 'data["version"]' "0.5.24" "$label does not publish the target version"
  assert_json_eq "$INSTALL_STATE_FILE" 'data["host_version"]' "0.5.24" "$label does not publish the target host version"
  assert_not_contains "0.5.31" "$(<"$finalization_output")" "$label reports a generalized finalization error"
  assert_contains "$expected_refusal" "$(<"$finalization_output")" "$label preserves the legacy safe refusal"
  assert_contains "predicate=$expected_predicate observed-state=not-canonical" "$(<"$finalization_output")" "$label reports generalized runtime truth"
}

install_finalization_publication_probe() {
  local original_update_install_state
  original_update_install_state="$(declare -f update_install_state)"
  original_update_install_state="${original_update_install_state/update_install_state /test_original_update_install_state }"
  eval "$original_update_install_state"
  update_install_state() {
    if [[ "$1" == "finalized" ]]; then
      ((FINALIZATION_PUBLICATION_CALLS += 1))
    fi
    test_original_update_install_state "$@"
  }
}

prepare_canonical_runtime_truth_case() {
  prepare_transaction_case
  FAKE_UMBREL_IMAGE_REF="$UMBREL_IMAGE"
  FAKE_UMBREL_IMAGE_ID="$FAKE_CANDIDATE_IMAGE_ID"
  FAKE_UMBREL_STATE="running"
  FAKE_UMBREL_DATA_SOURCE="$DATA_DIR"
  FAKE_UMBREL_DOCKER_SOCKET_SOURCE="/var/run/docker.sock"
  FAKE_UMBREL_RESTART_POLICY="always"
  FAKE_RUNTIME_DATA_IDENTITY_READY=1
  FAKE_AUTH_ID=""
  FAKE_AUTH_STATE="missing"
  FAKE_TOR_PROXY_ID=""
  FAKE_TOR_PROXY_STATE="missing"
  FAKE_UMBREL_AUTH_ID="canonical-umbrel-auth-id"
  FAKE_UMBREL_AUTH_STATE="running"
  FAKE_UMBREL_TOR_PROXY_ID="canonical-umbrel-tor-proxy-id"
  FAKE_UMBREL_TOR_PROXY_STATE="running"
  FAKE_UMBREL_TOR_PROXY_IMAGE="$TOR_PROXY_IMAGE"
  FAKE_SAFE_SHUTDOWN_COMPONENT="canonical"
  FAKE_HTTP_READY=1
}

assert_runtime_truth_reporter_read_only() {
  local label="$1"
  local runtime_log
  runtime_log="$(fake_docker_log_text)"
  for mutation in 'pull ' 'stop ' 'rm ' 'run ' 'start ' 'restart ' 'update '; do
    assert_not_contains "$mutation" "$runtime_log" "$label runtime-truth reporter must not mutate Docker"
  done
}

assert_runtime_truth_failure_preserves_state() {
  local label="$1"
  local expected_predicate="$2"
  local expected_state="$3"
  local before_state="$TEST_TMPDIR/$label-before.json"
  local finalization_output="$TEST_TMPDIR/$label-finalization.out"
  local publications_before="$FINALIZATION_PUBLICATION_CALLS"

  cp "$INSTALL_STATE_FILE" "$before_state"
  if finalize_install_state "0.5.31" >"$finalization_output" 2>&1; then
    fail "$label must reject image-correct runtime drift"
  fi
  cmp -s "$before_state" "$INSTALL_STATE_FILE" || fail "$label must leave install state byte-for-byte unchanged"
  assert_eq "$publications_before" "$FINALIZATION_PUBLICATION_CALLS" "$label must prevent final state publication"
  assert_runtime_truth_reporter_read_only "$label"
  assert_contains "predicate=$expected_predicate observed-state=$expected_state" "$(<"$finalization_output")" "$label reports its generalized runtime-truth diagnostic"
  assert_not_contains "$TEST_TMPDIR" "$(<"$finalization_output")" "$label diagnostic must not expose private local paths"
}

printf '[unit] full runtime-truth finalization contract failing first\n'
install_finalization_publication_probe
for runtime_truth_case in \
  'stopped-top-level:top-level-running-state:not-running' \
  'unsafe-data-identity:data-identity-binding:not-proven' \
  'missing-data-binding:data-identity-binding:not-proven' \
  'unsafe-data-alias:data-identity-binding:not-proven' \
  'wrong-docker-socket:docker-socket-mount:not-canonical' \
  'wrong-restart-policy:restart-policy:not-always' \
  'missing-canonical-system:system-container-contract:not-canonical' \
  'stopped-canonical-system:system-container-contract:not-canonical' \
  'invalid-tor-image:system-container-contract:not-canonical' \
  'missing-shutdown-source:safe-shutdown-contract:not-verified' \
  'missing-shutdown-ui:safe-shutdown-contract:not-verified' \
  'missing-shutdown-service:safe-shutdown-contract:not-verified' \
  'http-not-ready:http-readiness:not-responsive'; do
  IFS=':' read -r runtime_truth_failure expected_predicate expected_state <<<"$runtime_truth_case"
  prepare_canonical_runtime_truth_case
  case "$runtime_truth_failure" in
    stopped-top-level) FAKE_UMBREL_STATE="exited" ;;
    unsafe-data-identity) FAKE_RUNTIME_DATA_IDENTITY_READY=0 ;;
    missing-data-binding) FAKE_UMBREL_DATA_SOURCE="" ;;
    unsafe-data-alias) FAKE_UMBREL_DATA_SOURCE="$HOST_DATA_ALIAS" ;;
    wrong-docker-socket) FAKE_UMBREL_DOCKER_SOCKET_SOURCE="not-canonical" ;;
    wrong-restart-policy) FAKE_UMBREL_RESTART_POLICY="unless-stopped" ;;
    missing-canonical-system) FAKE_UMBREL_AUTH_ID="" ;;
    stopped-canonical-system) FAKE_UMBREL_TOR_PROXY_STATE="exited" ;;
    invalid-tor-image) FAKE_UMBREL_TOR_PROXY_IMAGE="ghcr.io/getumbrel/tor:invalid" ;;
    missing-shutdown-source) FAKE_SAFE_SHUTDOWN_COMPONENT="source-missing" ;;
    missing-shutdown-ui) FAKE_SAFE_SHUTDOWN_COMPONENT="ui-missing" ;;
    missing-shutdown-service) FAKE_SAFE_SHUTDOWN_COMPONENT="service-missing" ;;
    http-not-ready) FAKE_HTTP_READY=0 ;;
    *) fail "unknown runtime-truth drift fixture: $runtime_truth_failure" ;;
  esac
  assert_runtime_truth_failure_preserves_state "$runtime_truth_failure" "$expected_predicate" "$expected_state"
done

prepare_canonical_runtime_truth_case
finalize_install_state "0.5.31"
assert_eq "1" "$FINALIZATION_PUBLICATION_CALLS" "canonical runtime truth publishes exactly once"
assert_runtime_truth_reporter_read_only "canonical runtime truth"
assert_json_eq "$INSTALL_STATE_FILE" 'data["version"]' "0.5.31" "canonical runtime truth finalization writes the target version"
assert_json_eq "$INSTALL_STATE_FILE" 'data["image"]' "$UMBREL_IMAGE" "canonical runtime truth finalization records the verified image ref"
assert_json_eq "$INSTALL_STATE_FILE" 'data["image_id"]' "$FAKE_CANDIDATE_IMAGE_ID" "canonical runtime truth finalization records the verified image ID"
pass "full runtime-truth finalization rejects every image-correct drift class before publication"

write_current_version_metadata() {
  cat > "$INSTALL_STATE_FILE" <<JSON
{"host_version":"$SCRIPT_VERSION","version":"$SCRIPT_VERSION","image":"$UMBREL_IMAGE","image_id":"$FAKE_CANDIDATE_IMAGE_ID","applied_steps":[]}
JSON
}

printf '[unit] rollback image-ID configured-reference regression failing first\n'
prepare_canonical_runtime_truth_case
write_current_version_metadata
FAKE_OLD_IMAGE_ID="$FAKE_CANDIDATE_IMAGE_ID"
FAKE_ROLLBACK_RECORDS_IMAGE_ARGUMENT=1
rollback_umbrel_container "$FAKE_OLD_IMAGE_ID"
assert_eq "$FAKE_OLD_IMAGE_ID" "$FAKE_UMBREL_IMAGE_REF" "rollback records the actual image-ID docker run argument as Config.Image"
assert_eq "$FAKE_CANDIDATE_IMAGE_ID" "$FAKE_UMBREL_IMAGE_ID" "rollback live Image remains the expected candidate ID"
FAKE_AUTH_ID=""
FAKE_AUTH_STATE="missing"
FAKE_TOR_PROXY_ID=""
FAKE_TOR_PROXY_STATE="missing"
FAKE_UMBREL_AUTH_ID="canonical-umbrel-auth-id"
FAKE_UMBREL_AUTH_STATE="running"
FAKE_UMBREL_TOR_PROXY_ID="canonical-umbrel-tor-proxy-id"
FAKE_UMBREL_TOR_PROXY_STATE="running"
FAKE_UMBREL_TOR_PROXY_IMAGE="$TOR_PROXY_IMAGE"
rollback_snapshot_output="$TEST_TMPDIR/rollback-image-id-finalization.out"
set +e
finalize_install_state "$SCRIPT_VERSION" >"$rollback_snapshot_output" 2>&1
rollback_snapshot_status=$?
set -e
if [[ "$rollback_snapshot_status" -ne 0 ]]; then
  cat "$rollback_snapshot_output" >&2
  fail "rollback image-ID Config.Image resolving to the expected ID must satisfy snapshot and candidate readiness"
fi
assert_eq "1" "$FINALIZATION_PUBLICATION_CALLS" "rollback image-ID runtime finalization publishes exactly once"
assert_json_eq "$INSTALL_STATE_FILE" 'data["image"]' "$UMBREL_IMAGE" "rollback image-ID runtime publishes canonical Umbrel image metadata"
assert_json_eq "$INSTALL_STATE_FILE" 'data["image_id"]' "$FAKE_CANDIDATE_IMAGE_ID" "rollback image-ID runtime publishes the verified image ID"
pass "rollback image-ID configured reference resolves to the expected candidate and publishes canonical metadata"

printf '[unit] current-version runtime reconcile contract\n'
prepare_canonical_runtime_truth_case
write_current_version_metadata
current_before_sha="$(sha256sum "$INSTALL_STATE_FILE" | cut -d' ' -f1)"
current_publications_before="$FINALIZATION_PUBLICATION_CALLS"
reconcile_current_version_runtime "$SCRIPT_VERSION"
assert_eq "$current_before_sha" "$(sha256sum "$INSTALL_STATE_FILE" | cut -d' ' -f1)" "canonical current-version reconcile preserves state bytes"
assert_eq "$current_publications_before" "$FINALIZATION_PUBLICATION_CALLS" "canonical current-version reconcile does not publish state"
assert_runtime_truth_reporter_read_only "canonical current-version reconcile"

prepare_canonical_runtime_truth_case
cat > "$INSTALL_STATE_FILE" <<JSON
{"host_version":"$SCRIPT_VERSION","version":"$SCRIPT_VERSION","image":"dockurr/umbrel:stale","image_id":"sha256:stale-image-id","applied_steps":[]}
JSON
current_publications_before="$FINALIZATION_PUBLICATION_CALLS"
reconcile_current_version_runtime "$SCRIPT_VERSION"
assert_eq "$((current_publications_before + 1))" "$FINALIZATION_PUBLICATION_CALLS" "stale current-version metadata publishes exactly once after verification"
assert_json_eq "$INSTALL_STATE_FILE" 'data["version"]' "$SCRIPT_VERSION" "stale current-version metadata writes the target version"
assert_json_eq "$INSTALL_STATE_FILE" 'data["host_version"]' "$SCRIPT_VERSION" "stale current-version metadata writes the target host version"
assert_json_eq "$INSTALL_STATE_FILE" 'data["image"]' "$UMBREL_IMAGE" "stale current-version metadata writes the verified image"
assert_json_eq "$INSTALL_STATE_FILE" 'data["image_id"]' "$FAKE_CANDIDATE_IMAGE_ID" "stale current-version metadata writes the verified image ID"
assert_runtime_truth_reporter_read_only "stale current-version metadata reconcile"

for current_version_drift in top-image system restart shutdown http; do
  prepare_canonical_runtime_truth_case
  write_current_version_metadata
  case "$current_version_drift" in
    top-image) FAKE_UMBREL_IMAGE_REF="dockurr/umbrel:wrong" ;;
    system) FAKE_UMBREL_AUTH_ID="" ;;
    restart) FAKE_UMBREL_RESTART_POLICY="unless-stopped" ;;
    shutdown)
      FAKE_SAFE_SHUTDOWN_COMPONENT="source-missing"
      FAKE_REPAIR_CONVERGES_SAFE_SHUTDOWN=1
      ;;
    http)
      FAKE_HTTP_READY=0
      FAKE_REPAIR_CONVERGES_HTTP=1
      ;;
    *) fail "unknown current-version drift fixture: $current_version_drift" ;;
  esac
  current_publications_before="$FINALIZATION_PUBLICATION_CALLS"
  reconcile_current_version_runtime "$SCRIPT_VERSION"
  assert_eq "$((current_publications_before + 1))" "$FINALIZATION_PUBLICATION_CALLS" "$current_version_drift current-version repair publishes after convergence"
  assert_json_eq "$INSTALL_STATE_FILE" 'data["image"]' "$UMBREL_IMAGE" "$current_version_drift current-version repair records the verified image"
  assert_json_eq "$INSTALL_STATE_FILE" 'data["image_id"]' "$FAKE_CANDIDATE_IMAGE_ID" "$current_version_drift current-version repair records the verified image ID"
  assert_eq "1" "$(grep -cF "pull $UMBREL_IMAGE" <<<"$(fake_docker_log_text)" || true)" "$current_version_drift current-version repair runs one bounded candidate transaction"
done

printf '[unit] current-version repair waits for post-safe-shutdown system convergence\n'
prepare_canonical_runtime_truth_case
write_current_version_metadata
FAKE_UMBREL_RESTART_POLICY="unless-stopped"
FAKE_POSTCHECK_MUTATION="delayed_system_readiness"
FAKE_POST_SAFE_SHUTDOWN_SYSTEM_MODE="delayed"
FAKE_POST_SAFE_SHUTDOWN_SYSTEM_DELAY=2
CANDIDATE_READINESS_ATTEMPTS=3
current_repair_publications_before="$FINALIZATION_PUBLICATION_CALLS"
current_repair_output_file="$TEST_TMPDIR/current-version-delayed-system-readiness.out"
if ! reconcile_current_version_runtime "$SCRIPT_VERSION" >"$current_repair_output_file" 2>&1; then
  cat "$current_repair_output_file" >&2
  fail "current-version repair must wait for delayed canonical system containers after safe-shutdown installation"
fi
current_repair_log="$(fake_docker_log_text)"
assert_eq "3" "$FAKE_POST_SAFE_SHUTDOWN_SYSTEM_READINESS_CALLS" "current-version repair polls delayed system readiness until the third bounded attempt"
assert_eq "2" "$FAKE_SLEEP_CALLS" "current-version repair sleeps only between bounded system-readiness attempts"
assert_eq "0" "$UMBREL_TRANSACTION_ACTIVE" "current-version repair completes its single transaction after full runtime truth"
assert_eq "$((current_repair_publications_before + 1))" "$FINALIZATION_PUBLICATION_CALLS" "current-version repair publishes once only after full runtime truth"
assert_eq "1" "$(grep -cF "pull $UMBREL_IMAGE" <<<"$current_repair_log" || true)" "current-version repair pulls one candidate image"
assert_eq "0" "$(grep -cF "run -d --name umbrel --restart always -p 80:80 -v $DATA_DIR:/data -v /var/run/docker.sock:/var/run/docker.sock --stop-timeout 60 --pid=host --privileged $FAKE_CANDIDATE_IMAGE_ID" <<<"$current_repair_log" || true)" "current-version repair does not roll back after delayed system convergence"
assert_eq "running" "$FAKE_BITCOIN_STATE" "current-version repair restores the unrelated ordinary app"
assert_json_eq "$INSTALL_STATE_FILE" 'data["version"]' "$SCRIPT_VERSION" "current-version delayed repair publishes canonical version metadata"
assert_json_eq "$INSTALL_STATE_FILE" 'data["host_version"]' "$SCRIPT_VERSION" "current-version delayed repair publishes canonical host metadata"
assert_json_eq "$INSTALL_STATE_FILE" 'data["image"]' "$UMBREL_IMAGE" "current-version delayed repair publishes canonical image metadata"
assert_json_eq "$INSTALL_STATE_FILE" 'data["image_id"]' "$FAKE_CANDIDATE_IMAGE_ID" "current-version delayed repair publishes canonical image-ID metadata"

prepare_canonical_runtime_truth_case
write_current_version_metadata
FAKE_UMBREL_RESTART_POLICY="unless-stopped"
FAKE_POSTCHECK_MUTATION="permanent_missing_system_readiness"
CANDIDATE_READINESS_ATTEMPTS=3
current_timeout_state_before="$TEST_TMPDIR/current-version-system-timeout-before.json"
cp "$INSTALL_STATE_FILE" "$current_timeout_state_before"
current_timeout_publications_before="$FINALIZATION_PUBLICATION_CALLS"
current_timeout_output_file="$TEST_TMPDIR/current-version-system-timeout.out"
set +e
reconcile_current_version_runtime "$SCRIPT_VERSION" >"$current_timeout_output_file" 2>&1
current_timeout_status=$?
set -e
current_timeout_output="$(<"$current_timeout_output_file")"
[[ "$current_timeout_status" -ne 0 ]] || fail "permanent current-version system-container non-convergence must fail"
assert_eq "3" "$FAKE_POST_SAFE_SHUTDOWN_SYSTEM_READINESS_CALLS" "current-version timeout uses every bounded system-readiness attempt"
assert_eq "2" "$FAKE_SLEEP_CALLS" "current-version timeout sleeps only between bounded system-readiness attempts"
assert_eq "1" "$(grep -cF "pull $UMBREL_IMAGE" <<<"$(fake_docker_log_text)" || true)" "current-version timeout still runs one candidate transaction"
assert_eq "1" "$(grep -cF "run -d --name umbrel --restart always -p 80:80 -v $DATA_DIR:/data -v /var/run/docker.sock:/var/run/docker.sock --stop-timeout 60 --pid=host --privileged $FAKE_CANDIDATE_IMAGE_ID" <<<"$(fake_docker_log_text)" || true)" "current-version timeout rolls back once"
assert_eq "$current_timeout_publications_before" "$FINALIZATION_PUBLICATION_CALLS" "current-version timeout does not publish final metadata"
cmp -s "$current_timeout_state_before" "$INSTALL_STATE_FILE" || fail "current-version timeout preserves pre-repair install-state bytes"
assert_contains "Current-version system-container convergence did not complete within bounded readiness attempts." "$current_timeout_output" "current-version timeout reports generalized system-container convergence"
assert_not_contains "$TEST_TMPDIR" "$current_timeout_output" "current-version timeout diagnostic must not expose temporary paths"
pass "current-version repair waits once for post-safe-shutdown system convergence and rolls back on timeout"

for current_version_unsafe in identity missing-data-binding wrong-docker-socket unsafe-data-alias missing-top-level; do
  prepare_canonical_runtime_truth_case
  write_current_version_metadata
  case "$current_version_unsafe" in
    identity) FAKE_RUNTIME_DATA_IDENTITY_READY=0 ;;
    missing-data-binding) FAKE_UMBREL_DATA_SOURCE="" ;;
    wrong-docker-socket) FAKE_UMBREL_DOCKER_SOCKET_SOURCE="not-canonical" ;;
    unsafe-data-alias) FAKE_UMBREL_DATA_SOURCE="$HOST_DATA_ALIAS" ;;
    missing-top-level) FAKE_UMBREL_CONTAINER_PRESENT=0 ;;
    *) fail "unknown unsafe current-version fixture: $current_version_unsafe" ;;
  esac
  current_before_sha="$(sha256sum "$INSTALL_STATE_FILE" | cut -d' ' -f1)"
  current_publications_before="$FINALIZATION_PUBLICATION_CALLS"
  if reconcile_current_version_runtime "$SCRIPT_VERSION" >/dev/null 2>&1; then
    fail "$current_version_unsafe current-version reconcile must fail closed"
  fi
  assert_eq "$current_before_sha" "$(sha256sum "$INSTALL_STATE_FILE" | cut -d' ' -f1)" "$current_version_unsafe current-version reconcile preserves state bytes"
  assert_eq "$current_publications_before" "$FINALIZATION_PUBLICATION_CALLS" "$current_version_unsafe current-version reconcile does not publish"
  assert_runtime_truth_reporter_read_only "$current_version_unsafe current-version reconcile"
done

for current_version_check in canonical stopped; do
  prepare_canonical_runtime_truth_case
  write_current_version_metadata
  if [[ "$current_version_check" == "stopped" ]]; then
    FAKE_UMBREL_STATE="exited"
  fi
  current_before_sha="$(sha256sum "$INSTALL_STATE_FILE" | cut -d' ' -f1)"
  current_publications_before="$FINALIZATION_PUBLICATION_CALLS"
  CHECK_ONLY=1
  current_check_output="$TEST_TMPDIR/$current_version_check-current-check.out"
  set +e
  reconcile_current_version_runtime "$SCRIPT_VERSION" >"$current_check_output" 2>&1
  current_check_status=$?
  set -e
  CHECK_ONLY=0
  if [[ "$current_version_check" == "canonical" ]]; then
    assert_eq "0" "$current_check_status" "canonical current-version check succeeds"
    assert_contains "predicate=all observed-state=canonical" "$(<"$current_check_output")" "canonical current-version check reports canonical truth"
  else
    [[ "$current_check_status" -ne 0 ]] || fail "stopped current-version check must fail"
    assert_contains "predicate=top-level-running-state observed-state=not-running" "$(<"$current_check_output")" "stopped current-version check reports the drift predicate"
  fi
  assert_eq "$current_before_sha" "$(sha256sum "$INSTALL_STATE_FILE" | cut -d' ' -f1)" "$current_version_check current-version check preserves state bytes"
  assert_eq "$current_publications_before" "$FINALIZATION_PUBLICATION_CALLS" "$current_version_check current-version check does not publish"
  assert_runtime_truth_reporter_read_only "$current_version_check current-version check"
done
pass "current-version reconcile reports check truth, repairs once after identity proof, and preserves canonical state"

printf '[unit] all-target runtime metadata finalization contract\n'
prepare_canonical_runtime_truth_case
cat > "$INSTALL_STATE_FILE" <<'JSON'
{"host_version":"0.5.26","version":"0.5.26","image":"dockurr/umbrel:1.7.3@sha256:old-image","applied_steps":[]}
JSON
FAKE_UMBREL_IMAGE_REF="$UMBREL_IMAGE"
FAKE_UMBREL_IMAGE_ID="$FAKE_CANDIDATE_IMAGE_ID"
finalize_install_state "0.5.31"
assert_json_eq "$INSTALL_STATE_FILE" 'data["version"]' "0.5.31" "stale public 0.5.26 state repairs the final version"
assert_json_eq "$INSTALL_STATE_FILE" 'data["host_version"]' "0.5.31" "stale public 0.5.26 state repairs the host version"
assert_json_eq "$INSTALL_STATE_FILE" 'data["image"]' "$UMBREL_IMAGE" "stale public 0.5.26 state repairs the live pinned image ref"
assert_json_eq "$INSTALL_STATE_FILE" 'data["image_id"]' "$FAKE_CANDIDATE_IMAGE_ID" "stale public 0.5.26 state repairs the missing live image ID"

prepare_transaction_case
FAKE_UMBREL_IMAGE_REF="dockurr/umbrel:wrong"
FAKE_UMBREL_IMAGE_ID="$FAKE_CANDIDATE_IMAGE_ID"
assert_finalization_failure_preserves_state "wrong-live-ref" "Refusing to finalize because the live Umbrel runtime image reference could not be verified." "top-level-image-reference"

prepare_transaction_case
FAKE_UMBREL_IMAGE_REF="$FAKE_DIFFERENT_IMAGE_ID"
FAKE_UMBREL_IMAGE_ID="$FAKE_CANDIDATE_IMAGE_ID"
assert_finalization_failure_preserves_state "different-id-image-id-live-ref" "Refusing to finalize because the live Umbrel runtime image reference could not be verified." "top-level-image-reference"

prepare_transaction_case
FAKE_UMBREL_IMAGE_REF="$UMBREL_IMAGE"
FAKE_UMBREL_IMAGE_ID="sha256:wrong-live-image-id"
assert_finalization_failure_preserves_state "wrong-live-id" "Refusing to finalize because the live Umbrel runtime image ID could not be verified." "top-level-image-id"

prepare_transaction_case
FAKE_UMBREL_CONTAINER_PRESENT=0
assert_finalization_failure_preserves_state "missing-container" "Refusing to finalize because the live Umbrel runtime image reference could not be verified." "top-level-image-reference"

prepare_transaction_case
FAKE_UMBREL_IMAGE_REF=""
FAKE_UMBREL_IMAGE_ID="$FAKE_CANDIDATE_IMAGE_ID"
assert_finalization_failure_preserves_state "empty-config-image" "Refusing to finalize because the live Umbrel runtime image reference could not be verified." "top-level-image-reference"

prepare_transaction_case
FAKE_UMBREL_IMAGE_REF="$UMBREL_IMAGE"
FAKE_UMBREL_IMAGE_ID=""
assert_finalization_failure_preserves_state "empty-image-id" "Refusing to finalize because the live Umbrel runtime image ID could not be verified." "top-level-image-id"

prepare_transaction_case
FAKE_UMBREL_IMAGE_REF="$UMBREL_IMAGE"
FAKE_UMBREL_IMAGE_ID="sha256:live-image-id"
FAKE_CANDIDATE_IMAGE_ID=""
assert_finalization_failure_preserves_state "unresolved-pinned-image-id" "Refusing to finalize because the live Umbrel runtime image ID could not be verified." "top-level-image-id"

prepare_canonical_runtime_truth_case
rm -f "$INSTALL_STATE_FILE"
[[ ! -e "$INSTALL_STATE_FILE" ]] || fail "no-state finalization fixture must start without install state"
finalize_install_state "0.5.31"
assert_json_eq "$INSTALL_STATE_FILE" 'data["version"]' "0.5.31" "no-state finalization creates the target version"
assert_json_eq "$INSTALL_STATE_FILE" 'data["host_version"]' "0.5.31" "no-state finalization creates the target host version"
assert_json_eq "$INSTALL_STATE_FILE" 'data["image"]' "$UMBREL_IMAGE" "no-state finalization creates the live pinned image ref"
assert_json_eq "$INSTALL_STATE_FILE" 'data["image_id"]' "$FAKE_CANDIDATE_IMAGE_ID" "no-state finalization creates the live image ID"

prepare_transaction_case
original_precheck_common_canonical_install="$(declare -f precheck_common_canonical_install)"
original_m1s_configure_avahi_mdns="$(declare -f m1s_configure_avahi_mdns)"
original_m1s_avahi_internal_health_check="$(declare -f m1s_avahi_internal_health_check)"
original_install_umbrel_safe_shutdown="$(declare -f install_umbrel_safe_shutdown)"
original_postcheck_umbrel_safe_shutdown="$(declare -f postcheck_umbrel_safe_shutdown)"
CHAIN_PRECHECK_CALLS=0
precheck_common_canonical_install() { ((CHAIN_PRECHECK_CALLS += 1)); }
m1s_configure_avahi_mdns() { :; }
m1s_avahi_internal_health_check() { :; }
install_umbrel_safe_shutdown() { :; }
postcheck_umbrel_safe_shutdown() { :; }
# shellcheck disable=SC2329 # Invoked indirectly by the final migration postcheck.
systemctl() { return 0; }
precheck_common_canonical_install
assert_eq "1" "$CHAIN_PRECHECK_CALLS" "chained migration fixture precheck stub is exercised before migration dispatch"
for chained_step in 0.5.24_to_0.5.25 0.5.25_to_0.5.26 0.5.26_to_0.5.27 0.5.27_to_0.5.28 0.5.28_to_0.5.29 0.5.29_to_0.5.30 0.5.30_to_0.5.31; do
  run_migration_step "$chained_step" || fail "chained migration $chained_step must complete before finalization"
done
assert_eq "7" "$CHAIN_PRECHECK_CALLS" "chained migration dispatch exercises the common precheck for every applicable later migration"
finalize_install_state "0.5.31"
eval "$original_precheck_common_canonical_install"
eval "$original_m1s_configure_avahi_mdns"
eval "$original_m1s_avahi_internal_health_check"
eval "$original_install_umbrel_safe_shutdown"
eval "$original_postcheck_umbrel_safe_shutdown"
unset -f systemctl
assert_json_eq "$INSTALL_STATE_FILE" 'data["version"]' "0.5.31" "0.5.24 to 0.5.31 chain publishes the final version only after runtime verification"
assert_json_eq "$INSTALL_STATE_FILE" 'data["host_version"]' "0.5.31" "0.5.24 to 0.5.31 chain publishes the final host version"
assert_json_eq "$INSTALL_STATE_FILE" 'data["image"]' "$UMBREL_IMAGE" "0.5.24 to 0.5.31 chain records the live pinned image ref"
assert_json_eq "$INSTALL_STATE_FILE" 'data["image_id"]' "$FAKE_CANDIDATE_IMAGE_ID" "0.5.24 to 0.5.31 chain records the resolved live image ID"

before_rerun_state="$TEST_TMPDIR/finalized-before-rerun.json"
cp "$INSTALL_STATE_FILE" "$before_rerun_state"
finalize_install_state "0.5.31"
assert_json_semantically_equal_excluding_updated_at "$before_rerun_state" "$INSTALL_STATE_FILE" "second successful finalization is semantically idempotent except timestamps"

prepare_transaction_case
FAKE_UMBREL_IMAGE_REF="$UMBREL_IMAGE"
FAKE_UMBREL_IMAGE_ID="$FAKE_CANDIDATE_IMAGE_ID"
dry_run_state="$TEST_TMPDIR/dry-run-before.json"
cp "$INSTALL_STATE_FILE" "$dry_run_state"
dry_run_docker_log="$(fake_docker_log_text)"
DRY_RUN=1
dry_run_output="$(finalize_install_state "0.5.31")"
DRY_RUN=0
assert_contains "skips live Umbrel runtime verification and final state publication" "$dry_run_output" "dry-run finalization must not claim runtime verification"
cmp -s "$dry_run_state" "$INSTALL_STATE_FILE" || fail "dry-run finalization must not write install state"
assert_eq "$dry_run_docker_log" "$(fake_docker_log_text)" "dry-run finalization must not inspect live Docker runtime"
pass "all-target finalization repairs live metadata, rejects bad runtime evidence, and remains idempotent"

for postcheck_diagnostic_case in \
  'mount_safety:mount-safety:not-safe' \
  'wrong_top_image:top-level-readiness:not-ready' \
  'missing_auth:system-container-readiness:not-ready' \
  'safe_shutdown:safe-shutdown-verification:not-verified' \
  'http:http-readiness:not-responsive'; do
  IFS=':' read -r transaction_failure expected_predicate expected_state <<<"$postcheck_diagnostic_case"
  prepare_transaction_case
  case "$transaction_failure" in
    mount_safety|wrong_top_image|missing_auth) FAKE_POSTCHECK_MUTATION="$transaction_failure" ;;
    safe_shutdown) FAKE_SAFE_SHUTDOWN_POSTCHECK_FAIL=1 ;;
    http) FAKE_HTTP_READY=0 ;;
  esac
  postcheck_output_file="$TEST_TMPDIR/postcheck-$transaction_failure.out"
  set +e
  run_migration_step "0.5.24_to_0.5.25" >"$postcheck_output_file" 2>&1
  postcheck_status=$?
  set -e
  postcheck_output="$(<"$postcheck_output_file")"
  [[ "$postcheck_status" -ne 0 ]] || fail "$transaction_failure must fail the 0.5.25 postcheck"
  assert_contains "predicate=$expected_predicate observed-state=$expected_state" "$postcheck_output" "$transaction_failure identifies its failed postcheck predicate"
  assert_not_contains "$TEST_TMPDIR" "$postcheck_output" "$transaction_failure diagnostic must not expose temporary paths"
  assert_transaction_rolled_back "$transaction_failure diagnostic"
done

prepare_transaction_case
CANDIDATE_READINESS_ATTEMPTS=3
FAKE_POSTCHECK_MUTATION="delayed_system_readiness"
FAKE_POST_SAFE_SHUTDOWN_SYSTEM_MODE="delayed"
FAKE_POST_SAFE_SHUTDOWN_SYSTEM_DELAY=2
if ! run_migration_step "0.5.24_to_0.5.25"; then
  fail "delayed canonical system-container recreation must converge during the 0.5.25 postcheck"
fi
assert_eq "3" "$FAKE_POST_SAFE_SHUTDOWN_SYSTEM_READINESS_CALLS" "delayed system readiness converges on the third bounded attempt"
assert_eq "2" "$FAKE_SLEEP_CALLS" "delayed system readiness waits only between bounded attempts"
assert_eq "0" "$UMBREL_TRANSACTION_ACTIVE" "delayed system readiness completes the transaction without rollback"

for permanent_system_readiness_case in permanent_missing_system_readiness permanent_wrong_tor_readiness; do
  prepare_transaction_case
  CANDIDATE_READINESS_ATTEMPTS=3
  FAKE_POSTCHECK_MUTATION="$permanent_system_readiness_case"
  postcheck_output_file="$TEST_TMPDIR/postcheck-$permanent_system_readiness_case.out"
  set +e
  run_migration_step "0.5.24_to_0.5.25" >"$postcheck_output_file" 2>&1
  postcheck_status=$?
  set -e
  postcheck_output="$(<"$postcheck_output_file")"
  [[ "$postcheck_status" -ne 0 ]] || fail "$permanent_system_readiness_case must exhaust postcheck system readiness"
  assert_eq "3" "$FAKE_POST_SAFE_SHUTDOWN_SYSTEM_READINESS_CALLS" "$permanent_system_readiness_case uses every bounded readiness attempt"
  assert_eq "2" "$FAKE_SLEEP_CALLS" "$permanent_system_readiness_case waits only between bounded attempts"
  assert_contains "predicate=system-container-readiness observed-state=not-ready" "$postcheck_output" "$permanent_system_readiness_case preserves the system readiness diagnostic"
  assert_transaction_rolled_back "$permanent_system_readiness_case"
done

for transaction_failure in candidate_start safe_shutdown http wrong_top_image missing_auth wrong_tor postcheck; do
  prepare_transaction_case
  case "$transaction_failure" in
    candidate_start) FAKE_CANDIDATE_RUN_FAIL=1 ;;
    safe_shutdown) FAKE_SAFE_SHUTDOWN_APPLY_FAIL=1 ;;
    http) FAKE_HTTP_READY=0 ;;
    wrong_top_image|missing_auth|wrong_tor) FAKE_POSTCHECK_MUTATION="$transaction_failure" ;;
    postcheck) FAKE_SAFE_SHUTDOWN_POSTCHECK_FAIL=1 ;;
  esac
  if run_migration_step "0.5.24_to_0.5.25"; then
    fail "$transaction_failure must fail the 0.5.25 transaction"
  fi
  assert_transaction_rolled_back "$transaction_failure"
  assert_json_eq "$INSTALL_STATE_FILE" 'data["host_version"]' "0.5.24" "$transaction_failure does not publish 0.5.25"
done

prepare_transaction_case
FAKE_APP_STOP_STATUS=2
if run_migration_step "0.5.24_to_0.5.25"; then
  fail "ordinary app stop status 2 must fail the 0.5.25 transaction"
fi
assert_transaction_rolled_back "ordinary app stop failure"
assert_contains "candidate start failed" "$(read_json_value "$INSTALL_STATE_FILE" 'data["last_error"]')" "ordinary app stop failure writes a migration failure message"
assert_eq "[]" "$(read_json_value "$INSTALL_STATE_FILE" 'data["applied_steps"]')" "ordinary app stop failure does not record completion"

prepare_transaction_case
FAKE_CANDIDATE_RUNTIME_IMAGE_ID="sha256:wrong-image-id"
FAKE_ROLLBACK_RUN_FAIL=1
if run_migration_step "0.5.24_to_0.5.25"; then
  fail "rollback start failure must fail the transaction"
fi
assert_contains "rollback failed" "$(read_json_value "$INSTALL_STATE_FILE" 'data["last_error"]')" "rollback start failure remains explicit"
assert_json_eq "$INSTALL_STATE_FILE" 'data["host_version"]' "0.5.24" "rollback start failure does not publish 0.5.25"

prepare_transaction_case
printf '{invalid JSON\n' > "$INSTALL_STATE_FILE"
if run_migration_step "0.5.24_to_0.5.25"; then
  fail "invalid install state JSON must fail precheck"
fi
candidate_log="$(fake_docker_log_text)"
assert_not_contains "stop " "$candidate_log" "invalid install state does not stop containers"
assert_not_contains "rm " "$candidate_log" "invalid install state does not remove containers"

prepare_transaction_case
run_migration_step "0.5.24_to_0.5.25"
assert_json_eq "$INSTALL_STATE_FILE" 'data["image"]' "$FAKE_OLD_IMAGE_REF" "completed transaction does not publish target image before finalization"
assert_json_eq "$INSTALL_STATE_FILE" 'data["image_id"]' "$FAKE_OLD_IMAGE_ID" "completed transaction does not publish target image ID before finalization"
finalize_install_state "0.5.25"
assert_json_eq "$INSTALL_STATE_FILE" 'data["host_version"]' "0.5.25" "successful transaction finalizes the target version"
assert_json_eq "$INSTALL_STATE_FILE" 'data["image"]' "$UMBREL_IMAGE" "successful transaction writes the exact live target ref"
assert_json_eq "$INSTALL_STATE_FILE" 'data["image_id"]' "$FAKE_CANDIDATE_IMAGE_ID" "successful transaction writes the live target image ID"
assert_json_eq "$INSTALL_STATE_FILE" 'data["failed_step"]' "null" "successful transaction clears failure state"

prepare_transaction_case
run_migration_step "0.5.24_to_0.5.25"
FAKE_UMBREL_IMAGE_ID="sha256:wrong-live-image-id"
if finalize_install_state "0.5.25"; then
  fail "wrong live image must prevent finalization"
fi
assert_json_eq "$INSTALL_STATE_FILE" 'data["host_version"]' "0.5.24" "failed finalization does not publish 0.5.25"

prepare_transaction_case
FAKE_SAFE_SHUTDOWN_APPLY_FAIL=1
if run_migration_step "0.5.24_to_0.5.25"; then
  fail "failed rerun setup must fail"
fi
FAKE_SAFE_SHUTDOWN_APPLY_FAIL=0
run_migration_step "0.5.24_to_0.5.25"
assert_json_eq "$INSTALL_STATE_FILE" 'data["failed_step"]' "null" "successful rerun clears stale failure state"
assert_json_missing "$INSTALL_STATE_FILE" "last_attempted_image"
candidate_log_before="$(fake_docker_log_text)"
run_migration_step "0.5.24_to_0.5.25"
assert_eq "$candidate_log_before" "$(fake_docker_log_text)" "already-completed transaction does not replace containers again"
pass "0.5.25 transaction rolls back all failure boundaries and finalizes runtime truth"

if [[ "${M1S_TEST_RUNTIME_TRUTH_QA:-0}" -eq 1 ]]; then
  printf '[qa] runtime-truth finalization sourced-shell seam\n'
  prepare_canonical_runtime_truth_case
  set +e
  finalize_install_state "0.5.31"
  canonical_status=$?
  set -e
  assert_eq "0" "$canonical_status" "canonical sourced-shell finalization must succeed"
  assert_eq "1" "$FINALIZATION_PUBLICATION_CALLS" "canonical sourced-shell finalization publishes once"
  assert_json_eq "$INSTALL_STATE_FILE" 'data["image"]' "$UMBREL_IMAGE" "canonical sourced-shell finalization records image metadata"
  printf '[qa] canonical-finalize-status=%s publications=%s image-metadata=verified\n' "$canonical_status" "$FINALIZATION_PUBLICATION_CALLS"

  prepare_canonical_runtime_truth_case
  FAKE_UMBREL_STATE="exited"
  noncanonical_before_sha="$(sha256sum "$INSTALL_STATE_FILE" | cut -d' ' -f1)"
  noncanonical_output="$TEST_TMPDIR/qa-noncanonical-finalization.out"
  set +e
  finalize_install_state "0.5.31" >"$noncanonical_output" 2>&1
  noncanonical_status=$?
  set -e
  noncanonical_after_sha="$(sha256sum "$INSTALL_STATE_FILE" | cut -d' ' -f1)"
  [[ "$noncanonical_status" -ne 0 ]] || fail "image-correct noncanonical sourced-shell finalization must fail"
  assert_eq "0" "$FINALIZATION_PUBLICATION_CALLS" "image-correct noncanonical sourced-shell finalization must not publish"
  assert_eq "$noncanonical_before_sha" "$noncanonical_after_sha" "image-correct noncanonical sourced-shell finalization must preserve state bytes"
  assert_contains 'predicate=top-level-running-state observed-state=not-running' "$(<"$noncanonical_output")" "image-correct noncanonical sourced-shell finalization reports runtime state"
  assert_not_contains "$TEST_TMPDIR" "$(<"$noncanonical_output")" "image-correct noncanonical sourced-shell finalization keeps diagnostics generalized"
  printf '[qa] noncanonical-finalize-status=%s publications=%s state-sha-unchanged=1 diagnostic=top-level-running-state:not-running\n' "$noncanonical_status" "$FINALIZATION_PUBLICATION_CALLS"
fi

if [[ "${M1S_TEST_CURRENT_VERSION_MAIN_QA:-0}" -eq 1 ]]; then
  printf '[qa] current-version main sourced-shell seam\n'
  original_require_root="$(declare -f require_root)"
  original_sync_repository_to_origin_main="$(declare -f sync_repository_to_origin_main)"
  original_detect_installed_version="$(declare -f detect_installed_version)"
  original_ensure_fullnode_mount_from_state="$(declare -f ensure_fullnode_mount_from_state)"
  require_root() { return 0; }
  sync_repository_to_origin_main() { return 0; }
  ensure_fullnode_mount_from_state() { : > "$TEST_TMPDIR/current-version-main-mount"; }

  prepare_canonical_runtime_truth_case
  write_current_version_metadata
  detect_installed_version() { printf '%s\n' "$SCRIPT_VERSION"; }
  canonical_main_before_sha="$(sha256sum "$INSTALL_STATE_FILE" | cut -d' ' -f1)"
  canonical_main_publications="$FINALIZATION_PUBLICATION_CALLS"
  set +e
  CHECK_ONLY=0 main --skip-sync > "$TEST_TMPDIR/current-version-main-canonical.out" 2>&1
  canonical_main_status=$?
  set -e
  assert_eq "0" "$canonical_main_status" "canonical current-version main succeeds"
  assert_eq "$canonical_main_before_sha" "$(sha256sum "$INSTALL_STATE_FILE" | cut -d' ' -f1)" "canonical current-version main preserves state bytes"
  assert_eq "$canonical_main_publications" "$FINALIZATION_PUBLICATION_CALLS" "canonical current-version main does not publish"
  [[ ! -e "$TEST_TMPDIR/current-version-main-mount" ]] || fail "canonical current-version main does not repair mounts"
  assert_runtime_truth_reporter_read_only "canonical current-version main"

  prepare_canonical_runtime_truth_case
  write_current_version_metadata
  detect_installed_version() { printf '%s\n' "$SCRIPT_VERSION"; }
  FAKE_UMBREL_STATE="exited"
  repair_main_publications="$FINALIZATION_PUBLICATION_CALLS"
  set +e
  CHECK_ONLY=0 main --skip-sync > "$TEST_TMPDIR/current-version-main-repair.out" 2>&1
  repair_main_status=$?
  set -e
  assert_eq "0" "$repair_main_status" "repairable current-version main succeeds"
  assert_eq "$((repair_main_publications + 1))" "$FINALIZATION_PUBLICATION_CALLS" "repairable current-version main publishes after verification"
  assert_eq "1" "$(grep -cF "pull $UMBREL_IMAGE" <<<"$(fake_docker_log_text)" || true)" "repairable current-version main runs one bounded repair"

  prepare_canonical_runtime_truth_case
  write_current_version_metadata
  detect_installed_version() { printf '%s\n' "$SCRIPT_VERSION"; }
  FAKE_RUNTIME_DATA_IDENTITY_READY=0
  unsafe_main_before_sha="$(sha256sum "$INSTALL_STATE_FILE" | cut -d' ' -f1)"
  unsafe_main_publications="$FINALIZATION_PUBLICATION_CALLS"
  set +e
  CHECK_ONLY=0 main --skip-sync > "$TEST_TMPDIR/current-version-main-unsafe.out" 2>&1
  unsafe_main_status=$?
  set -e
  [[ "$unsafe_main_status" -ne 0 ]] || fail "unsafe current-version main must fail closed"
  assert_eq "$unsafe_main_before_sha" "$(sha256sum "$INSTALL_STATE_FILE" | cut -d' ' -f1)" "unsafe current-version main preserves state bytes"
  assert_eq "$unsafe_main_publications" "$FINALIZATION_PUBLICATION_CALLS" "unsafe current-version main does not publish"
  assert_runtime_truth_reporter_read_only "unsafe current-version main"

  prepare_canonical_runtime_truth_case
  write_current_version_metadata
  detect_installed_version() { printf '%s\n' "$SCRIPT_VERSION"; }
  FAKE_UMBREL_STATE="exited"
  check_main_before_sha="$(sha256sum "$INSTALL_STATE_FILE" | cut -d' ' -f1)"
  check_main_publications="$FINALIZATION_PUBLICATION_CALLS"
  set +e
  CHECK_ONLY=0 main --check --skip-sync > "$TEST_TMPDIR/current-version-main-check.out" 2>&1
  check_main_status=$?
  set -e
  [[ "$check_main_status" -ne 0 ]] || fail "stopped current-version main check must fail"
  assert_eq "$check_main_before_sha" "$(sha256sum "$INSTALL_STATE_FILE" | cut -d' ' -f1)" "current-version main check preserves state bytes"
  assert_eq "$check_main_publications" "$FINALIZATION_PUBLICATION_CALLS" "current-version main check does not publish"
  [[ ! -e "$TEST_TMPDIR/current-version-main-mount" ]] || fail "current-version main check does not repair mounts"
  assert_runtime_truth_reporter_read_only "current-version main check"

  prepare_canonical_runtime_truth_case
  write_current_version_metadata
  detect_installed_version() { printf '0.5.31\n'; }
  newer_main_before_sha="$(sha256sum "$INSTALL_STATE_FILE" | cut -d' ' -f1)"
  newer_main_publications="$FINALIZATION_PUBLICATION_CALLS"
  set +e
  CHECK_ONLY=0 main --skip-sync > "$TEST_TMPDIR/current-version-main-newer.out" 2>&1
  newer_main_status=$?
  set -e
  assert_eq "0" "$newer_main_status" "newer current-version main exits successfully"
  assert_eq "$newer_main_before_sha" "$(sha256sum "$INSTALL_STATE_FILE" | cut -d' ' -f1)" "newer current-version main preserves state bytes"
  assert_eq "$newer_main_publications" "$FINALIZATION_PUBLICATION_CALLS" "newer current-version main does not publish"
  [[ ! -e "$TEST_TMPDIR/current-version-main-mount" ]] || fail "newer current-version main does not repair mounts"
  assert_runtime_truth_reporter_read_only "newer current-version main"

  eval "$original_require_root"
  eval "$original_sync_repository_to_origin_main"
  eval "$original_detect_installed_version"
  eval "$original_ensure_fullnode_mount_from_state"
  printf '[qa] canonical-status=%s repair-status=%s unsafe-status=%s check-status=%s newer-status=%s repair-count=1\n' "$canonical_main_status" "$repair_main_status" "$unsafe_main_status" "$check_main_status" "$newer_main_status"
fi

unset -f docker

cleanup_test_state
printf '[unit] updater migration tests complete\n'
