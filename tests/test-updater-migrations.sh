#!/usr/bin/env bash
set -Eeuo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

# shellcheck source=scripts/m1s-update-umbrel.sh
source scripts/m1s-update-umbrel.sh

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
pass "build_migration_plan covers full, partial, and current installs"

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
finalize_install_state "0.4.12"
assert_json_eq "$INSTALL_STATE_FILE" 'data["version"]' "0.4.12" "finalize writes version"
assert_json_eq "$INSTALL_STATE_FILE" 'data["host_version"]' "0.4.12" "finalize writes host_version"
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
EVENTS=()
run_migration_step "9.0.0_to_9.0.1"
assert_eq "" "${EVENTS[*]}" "already applied step is skipped without rerunning handlers"
pass "run_migration_step succeeds, records progress, and skips applied steps"

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

printf '[unit] updater patches pinned 1.7.4 shutdown UI timer branch\n'
with_test_state
FAKE_UI_ROOT="$TEST_TMPDIR/umbreld-ui"
FAKE_UI_ASSET_DIR="$FAKE_UI_ROOT/assets"
mkdir -p "$FAKE_UI_ASSET_DIR"
source_callback='he==="shutting-down"&&!v&&(ce.isError||ce.failureCount>0)&&(b(!0),setTimeout(()=>S(!0),30*Kh))'
target_callback='he==="shutting-down"&&!v&&(b(!0),setTimeout(()=>S(!0),30*Kh))'
# shellcheck disable=SC2016 # Literal React Compiler minified variable names.
memo_prefix='let $e;e[56]!==v||e[57]!==he||e[58]!==ce.failureCount||e[59]!==ce.isError?($e=()=>{'
# shellcheck disable=SC2016 # Literal React Compiler minified variable names.
memo_suffix='},e[56]=v,e[57]=he,e[58]=ce.failureCount,e[59]=ce.isError,e[60]=$e):$e=e[60];let We;e[61]!==v||e[62]!==he||e[63]!==ce.failureCount||e[64]!==ce.isError||e[65]!==a?(We=[v,he,ce.failureCount,ce.isError,a],e[61]=v,e[62]=he,e[63]=ce.failureCount,e[64]=ce.isError,e[65]=a,e[66]=We):We=e[66],C.useEffect($e,We)'
source_region="${memo_prefix}${source_callback}${memo_suffix}"
target_region="${memo_prefix}${target_callback}${memo_suffix}"
asset_path="$FAKE_UI_ASSET_DIR/index-7c0be990.js"
printf 'before;%s;after\n' "$source_region" > "$asset_path"
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
if verify_umbrel_shutdown_ui >/dev/null 2>&1; then
  fail "updater shutdown UI verify must reject the current error-gated compiled branch before patching"
fi
patch_umbrel_shutdown_ui
verify_umbrel_shutdown_ui
patched_asset="$(<"$asset_path")"
assert_contains "$target_region" "$patched_asset" "patched updater asset should start the 30s timer from shutting-down state alone while preserving React memo/deps"
assert_contains "$memo_suffix" "$patched_asset" "patched updater asset should preserve the React Compiler dependency array"
assert_not_contains "$source_callback" "$patched_asset" "patched updater asset should remove only the query-error gate from the callback"
patch_umbrel_shutdown_ui
assert_eq "$patched_asset" "$(<"$asset_path")" "updater shutdown UI patch should be idempotent"
printf 'prefix;%s;%s\n' "$source_region" "$source_region" > "$asset_path"
if patch_umbrel_shutdown_ui >/dev/null 2>&1; then
  fail "updater shutdown UI patch must fail closed when the compiled branch is ambiguous"
fi
printf 'prefix;%s;%s\n' "$source_region" "$target_region" > "$asset_path"
if patch_umbrel_shutdown_ui >/dev/null 2>&1; then
  fail "updater shutdown UI patch must fail closed when source and patched branches coexist"
fi
printf 'prefix;%s;%s\n' "$target_region" "$target_region" > "$asset_path"
if verify_umbrel_shutdown_ui >/dev/null 2>&1; then
  fail "updater shutdown UI verify must fail closed when the patched branch is duplicated"
fi
printf 'prefix;unrelated shutdown bundle\n' > "$asset_path"
if verify_umbrel_shutdown_ui >/dev/null 2>&1; then
  fail "updater shutdown UI verify must fail when the compiled branch is absent"
fi
unset -f docker
pass "Updater replaces only the pinned 1.7.4 shutdown UI timer condition and fails closed"

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
  FAKE_CANDIDATE_IMAGE_ID="sha256:candidate-image-id"
  FAKE_CANDIDATE_RUNTIME_IMAGE_ID="$FAKE_CANDIDATE_IMAGE_ID"
  FAKE_CANDIDATE_AUTH_PRESENT=1
  FAKE_CANDIDATE_TOR_PRESENT=1
  FAKE_CANDIDATE_TOR_IMAGE="ghcr.io/getumbrel/tor:0.4.9.11"
  FAKE_UMBREL_IMAGE_ID="sha256:old-image-id"
  FAKE_UMBREL_IMAGE_REF="dockurr/umbrel:1.7.3@sha256:old-image"
  FAKE_OLD_IMAGE_ID="$FAKE_UMBREL_IMAGE_ID"
  FAKE_OLD_IMAGE_REF="$FAKE_UMBREL_IMAGE_REF"
  FAKE_UMBREL_STATE="running"
  FAKE_UMBREL_DATA_SOURCE="$DATA_DIR"
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
  [[ -n "$(fake_docker_container_id "$container" 2>/dev/null || true)" ]] || return 1

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
    *'.HostConfig.RestartPolicy.Name'*) printf 'always\n' ;;
    *'.Mounts'*)
      if [[ "$format" == *'/data'* ]]; then
        printf '%s\n' "$FAKE_UMBREL_DATA_SOURCE"
      elif [[ "$format" == *'/var/run/docker.sock'* ]]; then
        printf '/var/run/docker.sock\n'
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
      [[ "$FAKE_UMBREL_STATE" == "running" ]] && printf 'umbrel\n'
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
      [[ "$2" == "inspect" && "$3" == "$UMBREL_IMAGE" ]] || return 1
      printf '%s\n' "$FAKE_CANDIDATE_IMAGE_ID"
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
          umbrel) FAKE_UMBREL_IMAGE_ID="" ;;
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
        FAKE_UMBREL_IMAGE_ID="$FAKE_CANDIDATE_RUNTIME_IMAGE_ID"
        FAKE_UMBREL_IMAGE_REF="$UMBREL_IMAGE"
        FAKE_UMBREL_STATE="running"
        FAKE_UMBREL_DATA_SOURCE="$FAKE_RUN_DATA_SOURCE"
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
        FAKE_UMBREL_IMAGE_ID="$image_ref"
        FAKE_UMBREL_IMAGE_REF="$FAKE_OLD_IMAGE_REF"
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
  assert_fullnode_data_mount_safe() { [[ "$FAKE_POSTCHECK_MOUNT_FAILURE" -eq 0 ]]; }
  host_data_alias_ready() { return 1; }
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
  install_umbrel_safe_shutdown() {
    [[ "$FAKE_SAFE_SHUTDOWN_APPLY_FAIL" -eq 0 ]] || return 1
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
  postcheck_umbrel_safe_shutdown() { [[ "$FAKE_SAFE_SHUTDOWN_POSTCHECK_FAIL" -eq 0 ]]; }
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
  FAKE_HTTP_READY=1
  FAKE_POSTCHECK_MUTATION=""
  FAKE_POSTCHECK_MOUNT_FAILURE=0
  FAKE_POST_SAFE_SHUTDOWN_SYSTEM_ACTIVE=0
  FAKE_POST_SAFE_SHUTDOWN_SYSTEM_MODE=""
  FAKE_POST_SAFE_SHUTDOWN_SYSTEM_DELAY=0
  FAKE_POST_SAFE_SHUTDOWN_SYSTEM_READINESS_CALLS=0
  FAKE_SLEEP_CALLS=0
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
assert_eq "0.5.24_to_0.5.25" "${MIGRATIONS[$((${#MIGRATIONS[@]} - 1))]}" "0.5.25 transaction is the final migration"

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

unset -f docker

cleanup_test_state
printf '[unit] updater migration tests complete\n'
