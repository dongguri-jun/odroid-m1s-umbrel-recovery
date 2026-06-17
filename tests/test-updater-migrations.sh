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

cleanup_test_state
printf '[unit] updater migration tests complete\n'
