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
  DRY_RUN=0
  CHECK_ONLY=0
  mkdir -p "$DATA_DIR"
}

cleanup_test_state() {
  if [[ -n "${TEST_TMPDIR:-}" && -d "$TEST_TMPDIR" ]]; then
    rm -rf "$TEST_TMPDIR"
  fi
  unset TEST_TMPDIR || true
}

with_test_state() {
  cleanup_test_state
  new_test_state
}

printf '[unit] updater migration plan\n'
with_test_state
build_migration_plan "0.1.0"
assert_eq "15" "${#PLANNED_MIGRATIONS[@]}" "0.1.0 should plan every post-0.1 migration"
assert_eq "0.1.0_to_0.2.0" "${PLANNED_MIGRATIONS[0]}" "first planned migration from 0.1.0"
assert_eq "0.4.11_to_0.4.12" "${PLANNED_MIGRATIONS[14]}" "last planned migration from 0.1.0"
build_migration_plan "0.4.5"
assert_eq "7" "${#PLANNED_MIGRATIONS[@]}" "0.4.5 should plan bookkeeping and shutdown safety steps"
assert_eq "0.4.5_to_0.4.6" "${PLANNED_MIGRATIONS[0]}" "0.4.5 first planned migration"
assert_eq "0.4.11_to_0.4.12" "${PLANNED_MIGRATIONS[6]}" "0.4.5 final planned migration"
build_migration_plan "0.4.7"
assert_eq "5" "${#PLANNED_MIGRATIONS[@]}" "0.4.7 should plan backend-delay, frontend cleanup, stabilization, and browser-neutral container-stop migrations"
assert_eq "0.4.7_to_0.4.8" "${PLANNED_MIGRATIONS[0]}" "0.4.7 first planned migration"
assert_eq "0.4.11_to_0.4.12" "${PLANNED_MIGRATIONS[4]}" "0.4.7 final planned migration"
build_migration_plan "0.4.8"
assert_eq "4" "${#PLANNED_MIGRATIONS[@]}" "0.4.8 should plan frontend experiments, stabilization, and browser-neutral container-stop migrations"
assert_eq "0.4.8_to_0.4.9" "${PLANNED_MIGRATIONS[0]}" "0.4.8 first planned migration"
assert_eq "0.4.11_to_0.4.12" "${PLANNED_MIGRATIONS[3]}" "0.4.8 final planned migration"
build_migration_plan "0.4.9"
assert_eq "3" "${#PLANNED_MIGRATIONS[@]}" "0.4.9 should plan cache-bust, stabilization, and browser-neutral container-stop migrations"
assert_eq "0.4.9_to_0.4.10" "${PLANNED_MIGRATIONS[0]}" "0.4.9 first planned migration"
assert_eq "0.4.11_to_0.4.12" "${PLANNED_MIGRATIONS[2]}" "0.4.9 final planned migration"
build_migration_plan "0.4.10"
assert_eq "2" "${#PLANNED_MIGRATIONS[@]}" "0.4.10 should plan stabilization and browser-neutral container-stop migrations"
assert_eq "0.4.10_to_0.4.11" "${PLANNED_MIGRATIONS[0]}" "0.4.10 first planned migration"
assert_eq "0.4.11_to_0.4.12" "${PLANNED_MIGRATIONS[1]}" "0.4.10 final planned migration"
build_migration_plan "0.4.11"
assert_eq "1" "${#PLANNED_MIGRATIONS[@]}" "0.4.11 should plan browser-neutral container-stop migration"
assert_eq "0.4.11_to_0.4.12" "${PLANNED_MIGRATIONS[0]}" "0.4.11 planned migration"
build_migration_plan "0.4.12"
assert_eq "0" "${#PLANNED_MIGRATIONS[@]}" "0.4.12 should plan no migrations"
pass "build_migration_plan covers full, partial, and current installs"

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
parse_args --check --dry-run
assert_eq "1" "$CHECK_ONLY" "--check sets CHECK_ONLY"
assert_eq "1" "$DRY_RUN" "--dry-run sets DRY_RUN"
pass "parse_args handles check and dry-run flags"

cleanup_test_state
printf '[unit] updater migration tests complete\n'
