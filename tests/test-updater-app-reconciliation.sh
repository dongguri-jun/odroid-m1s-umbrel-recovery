#!/usr/bin/env bash
set -Eeuo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

# shellcheck source=scripts/m1s-update-umbrel.sh
source scripts/m1s-update-umbrel.sh

fail() {
  printf '[reconcile][FAIL] %s\n' "$1" >&2
  exit 1
}

pass() {
  printf '[reconcile][PASS] %s\n' "$1"
}

assert_started() {
  local container="$1"
  grep -Fxq "$container" "$FAKE_DOCKER_START_LOG" || fail "expected container to start: $container"
}

assert_not_started() {
  local container="$1"
  if grep -Fxq "$container" "$FAKE_DOCKER_START_LOG"; then
    fail "container must not start: $container"
  fi
}

assert_start_count() {
  local container="$1"
  local expected="$2"
  local count
  count="$(grep -Fxc "$container" "$FAKE_DOCKER_START_LOG" || true)"
  [[ "$count" == "$expected" ]] || fail "expected $container to start $expected time(s), got $count"
}

cleanup_test_state() {
  if [[ -n "${TEST_TMPDIR:-}" && -d "$TEST_TMPDIR" ]]; then
    rm -rf "$TEST_TMPDIR"
  fi
}

new_test_state() {
  cleanup_test_state
  TEST_TMPDIR="$(mktemp -d "${TMPDIR:-/tmp}/updater-app-reconciliation.XXXXXX")"
  INSTALL_STATE_DIR="$TEST_TMPDIR/etc/umbrel-recovery"
  INSTALL_STATE_FILE="$INSTALL_STATE_DIR/installed.json"
  DATA_DIR="$TEST_TMPDIR/mnt/fullnode"
  FSTAB_FILE="$TEST_TMPDIR/etc/fstab"
  FAKE_DOCKER_STATE="$TEST_TMPDIR/docker-state"
  FAKE_DOCKER_START_LOG="$TEST_TMPDIR/docker-start.log"
  FAKE_DOCKER_CALL_LOG="$TEST_TMPDIR/docker-call.log"
  AUTO_SYNC=0
  CHECK_ONLY=0
  DRY_RUN=0
  mkdir -p "$DATA_DIR" "$(dirname "$FSTAB_FILE")"
  : > "$FAKE_DOCKER_STATE"
  : > "$FAKE_DOCKER_START_LOG"
  : > "$FAKE_DOCKER_CALL_LOG"
}

trap cleanup_test_state EXIT

docker() {
  local container temporary_state
  printf '%s\n' "$*" >> "$FAKE_DOCKER_CALL_LOG"
  if [[ "${1:-}" == "ps" && "${2:-}" == "-a" ]]; then
    cat "$FAKE_DOCKER_STATE"
    return 0
  fi
  if [[ "${1:-}" == "container" && "${2:-}" == "inspect" ]]; then
    awk -v container="${3:-}" '$1 == container { found = 1 } END { exit !found }' "$FAKE_DOCKER_STATE"
    return
  fi
  if [[ "${1:-}" == "start" ]]; then
    for container in "${@:2}"; do
      printf '%s\n' "$container" >> "$FAKE_DOCKER_START_LOG"
      temporary_state="$FAKE_DOCKER_STATE.tmp"
      awk -v container="$container" '{ print $1, ($1 == container ? "running" : $2) }' "$FAKE_DOCKER_STATE" > "$temporary_state"
      mv "$temporary_state" "$FAKE_DOCKER_STATE"
    done
    return 0
  fi
  if [[ "${1:-}" == "pull" ]]; then
    return 0
  fi
  if [[ "${1:-}" == "image" && "${2:-}" == "inspect" ]]; then
    printf 'sha256:current-image-id\n'
    return 0
  fi
  fail "unexpected fake Docker call: $*"
}

printf '[reconcile] persisted app intent and idempotency\n'
new_test_state
mkdir -p \
  "$DATA_DIR/app-data/fresh" \
  "$DATA_DIR/app-data/enabled" \
  "$DATA_DIR/app-data/disabled" \
  "$DATA_DIR/app-data/already-running"
cat > "$DATA_DIR/umbrel.yaml" <<'EOF'
apps:
  - fresh
  - enabled
  - disabled
  - already-running
EOF
cat > "$DATA_DIR/app-data/fresh/settings.yml" <<'EOF'
dependencies: {}
EOF
cat > "$DATA_DIR/app-data/enabled/settings.yml" <<'EOF'
dependencies: {}
autoStart: true
EOF
cat > "$DATA_DIR/app-data/disabled/settings.yml" <<'EOF'
dependencies: {}
autoStart: false
EOF
cat > "$DATA_DIR/app-data/already-running/settings.yml" <<'EOF'
dependencies: {}
EOF
cat > "$FAKE_DOCKER_STATE" <<'EOF'
fresh_server_1 exited
fresh_app_proxy_1 exited
enabled_server_1 exited
disabled_server_1 exited
already-running_server_1 running
umbrel running
umbrel_auth running
EOF

reconcile_installed_app_containers || fail "persisted app intent reconciliation failed"
reconcile_installed_app_containers || fail "second reconciliation failed"
assert_started fresh_server_1
assert_started fresh_app_proxy_1
assert_started enabled_server_1
assert_not_started disabled_server_1
assert_not_started already-running_server_1
assert_not_started umbrel
assert_not_started umbrel_auth
assert_start_count fresh_server_1 1
assert_start_count fresh_app_proxy_1 1
assert_start_count enabled_server_1 1
pass "missing autoStart and autoStart true start only stopped existing containers; autoStart false and running containers remain untouched"

printf '[reconcile] missing metadata paths are clean no-ops\n'
new_test_state
rm -rf "$DATA_DIR"
reconcile_installed_app_containers || fail "missing data directory must be a clean no-op"
[[ ! -s "$FAKE_DOCKER_CALL_LOG" ]] || fail "missing data directory must not call Docker"

new_test_state
mkdir -p "$DATA_DIR/app-data"
reconcile_installed_app_containers || fail "missing umbrel.yaml must be a clean no-op"
[[ ! -s "$FAKE_DOCKER_CALL_LOG" ]] || fail "missing umbrel.yaml must not call Docker"

new_test_state
cat > "$DATA_DIR/umbrel.yaml" <<'EOF'
apps:
  - fresh
EOF
reconcile_installed_app_containers || fail "missing app-data must be a clean no-op"
[[ ! -s "$FAKE_DOCKER_CALL_LOG" ]] || fail "missing app-data must not call Docker"
pass "missing umbrel.yaml and app-data do not call Docker"

printf '[reconcile] candidate early return still reaches end-of-run reconciliation\n'
new_test_state
mkdir -p "$DATA_DIR/app-data/fresh"
cat > "$DATA_DIR/umbrel.yaml" <<'EOF'
apps:
  - fresh
EOF
cat > "$DATA_DIR/app-data/fresh/settings.yml" <<'EOF'
dependencies: {}
EOF
printf 'fresh_server_1 exited\n' > "$FAKE_DOCKER_STATE"

parse_args() { :; }
m1s_report_host_support() { :; }
require_root() { :; }
sync_repository_to_origin_main() { :; }
detect_installed_version() { printf '%s\n' "$SCRIPT_VERSION"; }
build_migration_plan() { PLANNED_MIGRATIONS=(); }
assert_fullnode_data_mount_safe() { return 0; }
capture_umbrel_transaction_context() {
  UMBREL_TRANSACTION_OLD_IMAGE_REF="$UMBREL_IMAGE"
  UMBREL_TRANSACTION_OLD_IMAGE_ID="sha256:current-image-id"
  UMBREL_TRANSACTION_DATA_SOURCE="$DATA_DIR"
  UMBREL_TRANSACTION_APP_CONTAINERS=()
}
umbrel_transaction_context_is_valid() { return 0; }
system_containers_need_replacement() { return 1; }
reconcile_current_version_runtime() {
  begin_umbrel_candidate_transaction
  [[ "$UMBREL_TRANSACTION_MUTATED" -eq 0 ]]
}

(run_updater) >/dev/null || fail "early-return updater run failed"
assert_started fresh_server_1
pass "non-mutating candidate early return still reconciles persisted app intent at updater exit"

printf '[reconcile] updater app reconciliation tests complete\n'
