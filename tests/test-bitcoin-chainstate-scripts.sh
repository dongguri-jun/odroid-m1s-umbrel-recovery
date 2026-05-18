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

printf '[unit] common recovery helpers\n'
(
  # shellcheck source=scripts/bitcoin-recovery-common.sh
  source scripts/bitcoin-recovery-common.sh

  TEST_TMPDIR="$(mktemp -d)"
  trap 'rm -rf "$TEST_TMPDIR"' EXIT

  DATA_DIR="$TEST_TMPDIR/mnt/fullnode"
  STATE_DIR="$TEST_TMPDIR/etc/umbrel-recovery"
  RECOVERY_STATE_FILE="$STATE_DIR/bitcoin-recovery.json"
  mkdir -p "$DATA_DIR/app-data/bitcoin/data/bitcoin"
  BITCOIN_CONFIG_DIR="$DATA_DIR/app-data/bitcoin/data/bitcoin"
  BITCOIN_APP_DATA_DIR="$DATA_DIR/app-data/bitcoin/data"
  BITCOIN_CONF="$BITCOIN_CONFIG_DIR/bitcoin.conf"
  UMBREL_BITCOIN_CONF="$BITCOIN_CONFIG_DIR/umbrel-bitcoin.conf"

  cat > "$UMBREL_BITCOIN_CONF" <<'EOF'
server=1
prune=0
EOF

  cat > "$BITCOIN_CONF" <<'EOF'
includeconf=umbrel-bitcoin.conf
# user custom options
foo=bar
EOF

  assert_eq 'reindex-chainstate=1' "$(mode_request_line chainstate-rebuild)" 'chainstate mode should map to reindex-chainstate flag'
  assert_eq 'reindex=1' "$(mode_request_line reindex)" 'reindex mode should map to reindex flag'
  assert_eq '' "$(mode_request_line full-resync)" 'full-resync should not set a config request flag'
  assert_contains "$(declare -f print_storage_diagnostics)" 'Recent kernel storage hints' 'status check should include storage diagnostics'
  assert_contains "$(declare -f print_storage_diagnostics)" 'Inode usage' 'storage diagnostics should include inode usage without repeating mount detail'
  assert_contains "$(declare -f print_recent_bitcoin_error_hints)" 'LevelDB' 'status check should include recent Bitcoin error hints'
  assert_contains "$(declare -f print_bitcoin_container_diagnostics)" 'Container state' 'status check should include container state'
  assert_contains "$(declare -f print_system_diagnostics)" 'Memory usage' 'status check should include system resource diagnostics'
  assert_contains "$(declare -f print_system_diagnostics)" 'Recent NVMe timeout snapshots' 'status check should include existing NVMe snapshot evidence'
  assert_contains "$(declare -f print_missing_bitcoin_config_status)" 'Bitcoin app config unavailable' 'status check should still print diagnostics when Bitcoin config is missing'

  located="$(locate_bitcoin_config_dir)"
  assert_eq "$BITCOIN_CONFIG_DIR" "$located" 'locate_bitcoin_config_dir should find the synthetic Umbrel path'

  settings_json="$(read_effective_settings_json)"
  assert_eq '0' "$(json_field "$settings_json" 'data["request_present"]')" 'request should not exist before mutation'
  require_safe_recovery_mode chainstate-rebuild "$settings_json"
  require_safe_recovery_mode reindex "$settings_json"
  require_safe_recovery_mode full-resync "$settings_json"

  write_status="$(write_request_block 'reindex-chainstate=1')"
  assert_eq 'added' "$write_status" 'write_request_block should add chainstate request'
  assert_contains "$(<"$BITCOIN_CONF")" 'reindex-chainstate=1' 'chainstate request should be written to bitcoin.conf'

  clear_status="$(clear_managed_request_block)"
  assert_eq 'removed' "$clear_status" 'clear_managed_request_block should remove managed request block'
  cleaned_conf="$(<"$BITCOIN_CONF")"
  [[ "$cleaned_conf" != *'reindex-chainstate=1'* ]] || fail 'managed chainstate request should be removed'

  ensure_state_dir
  write_recovery_state reindex 'reindex=1' 'test-script.sh'
  [[ -f "$RECOVERY_STATE_FILE" ]] || fail 'write_recovery_state should create state file'
  state_text="$(<"$RECOVERY_STATE_FILE")"
  assert_contains "$state_text" '"mode": "reindex"' 'state file should record recovery mode'
  assert_contains "$state_text" '"active_request": true' 'state file should mark active request'

  update_recovery_state_restart 1
  state_text="$(<"$RECOVERY_STATE_FILE")"
  assert_contains "$state_text" '"restart_succeeded": true' 'state file should record restart success'

  mark_data_reset_performed
  state_text="$(<"$RECOVERY_STATE_FILE")"
  assert_contains "$state_text" '"data_reset_performed": true' 'state file should record data reset when asked'

  mark_recovery_consumed consumed-by-test
  state_text="$(<"$RECOVERY_STATE_FILE")"
  assert_contains "$state_text" '"active_request": false' 'state file should clear active request when consumed'
  assert_contains "$state_text" '"last_observed_state": "consumed-by-test"' 'state file should record consumed state'
)
pass 'common recovery helpers handle flags and state tracking'

printf '[unit] chainstate guard rejects prune mode\n'
(
  # shellcheck source=scripts/bitcoin-recovery-common.sh
  source scripts/bitcoin-recovery-common.sh

  TEST_TMPDIR="$(mktemp -d)"
  trap 'rm -rf "$TEST_TMPDIR"' EXIT

  DATA_DIR="$TEST_TMPDIR/mnt/fullnode"
  mkdir -p "$DATA_DIR/app-data/bitcoin/data/bitcoin"
  BITCOIN_CONFIG_DIR="$DATA_DIR/app-data/bitcoin/data/bitcoin"
  BITCOIN_CONF="$BITCOIN_CONFIG_DIR/bitcoin.conf"
  UMBREL_BITCOIN_CONF="$BITCOIN_CONFIG_DIR/umbrel-bitcoin.conf"

  cat > "$UMBREL_BITCOIN_CONF" <<'EOF'
prune=1
EOF
  cat > "$BITCOIN_CONF" <<'EOF'
includeconf=umbrel-bitcoin.conf
EOF

  settings_json="$(read_effective_settings_json)"
  set +e
  guard_output="$(require_safe_recovery_mode chainstate-rebuild "$settings_json" 2>&1)"
  guard_status=$?
  set -e
  assert_eq '1' "$guard_status" 'prune guard should fail closed for chainstate rebuild'
  assert_contains "$guard_output" 'rejects reindex-chainstate in prune mode' 'prune guard should explain the reason'
)
pass 'chainstate rebuild fails closed when prune is enabled'

printf '[unit] compatibility wrappers advertise new commands\n'
request_help_output="$(bash scripts/m1s-request-bitcoin-chainstate-rebuild.sh --help)"
assert_contains "$request_help_output" 'm1s-start-bitcoin-chainstate-rebuild.sh' 'request wrapper should point to the chainstate start script'
check_help_output="$(bash scripts/m1s-check-bitcoin-chainstate-rebuild.sh --help)"
assert_contains "$check_help_output" 'm1s-check-bitcoin-recovery-status.sh' 'chainstate check wrapper should point to the unified recovery check'
pass 'compatibility wrappers document the new public entrypoints'

printf '[unit] unified recovery state resolution\n'
(
  # shellcheck source=scripts/bitcoin-recovery-common.sh
  source scripts/bitcoin-recovery-common.sh

  assert_eq 'recovery-in-progress' "$(resolve_recovery_status 1 1 1 1 0)" 'live recovery evidence should outrank other signals'
  assert_eq 'recovery-started-progress-unavailable' "$(resolve_recovery_status 1 0 1 1 0)" 'log evidence after request should imply start without progress'
  assert_eq 'request-recorded-restart-not-confirmed' "$(resolve_recovery_status 1 0 0 1 0)" 'active request without live confirmation should stay conservative'
  assert_eq 'recovery-not-currently-detected' "$(resolve_recovery_status 0 0 0 1 0)" 'consumed request without live evidence should report no active recovery'
  assert_eq 'recovery-inferred-from-runtime' "$(resolve_recovery_status 0 0 0 0 1)" 'known mode without tracked request should still infer runtime recovery'
  assert_eq 'no-recovery-detected' "$(resolve_recovery_status 0 0 0 0 0)" 'no evidence should report no recovery'
  assert_eq 'chainstate-rebuild' "$(resolve_recovery_mode '' 0 1 '' '')" 'chainstate config flag should imply chainstate mode'
  assert_eq 'reindex' "$(resolve_recovery_mode '' 1 0 '' '')" 'reindex config flag should imply reindex mode'
  assert_eq 'chainstate-rebuild' "$(resolve_recovery_mode 'unknown' 0 0 'chainstate-rebuild' '')" 'log hint should resolve unknown mode'
  assert_eq 'full-download' "$(resolve_recovery_mode 'unknown' 0 0 '' 'full-download')" 'runtime hint should resolve full download mode'
  assert_eq 'full-resync' "$(resolve_recovery_mode 'full-resync' 0 0 '' '')" 'state file mode should win when present'
)
pass 'unified recovery resolution covers mode and status'

printf '[unit] reindex log progress summary\n'
(
  # shellcheck source=scripts/bitcoin-recovery-common.sh
  source scripts/bitcoin-recovery-common.sh

  TEST_TMPDIR="$(mktemp -d)"
  trap 'rm -rf "$TEST_TMPDIR"' EXIT

  DATA_DIR="$TEST_TMPDIR/mnt/fullnode"
  mkdir -p "$DATA_DIR/app-data/bitcoin/data/bitcoin/blocks"
  BITCOIN_CONFIG_DIR="$DATA_DIR/app-data/bitcoin/data/bitcoin"
  DEBUG_LOG="$BITCOIN_CONFIG_DIR/debug.log"

  touch "$BITCOIN_CONFIG_DIR/blocks/blk00000.dat"
  touch "$BITCOIN_CONFIG_DIR/blocks/blk00001.dat"
  touch "$BITCOIN_CONFIG_DIR/blocks/blk00002.dat"

  cat > "$DEBUG_LOG" <<'EOF'
2026-05-11T09:08:35Z Pre-request noise
2026-05-11T09:08:36Z Reindexing block file blk00000.dat...
2026-05-11T09:09:01Z Loaded 120 blocks from external file in 1234ms
2026-05-11T09:10:00Z Reindexing block file blk00001.dat...
2026-05-11T09:10:45Z Loaded 250 blocks from external file in 5321ms
EOF

  summary_json="$(summarize_reindex_log_progress 1746954516)"
  assert_eq 'blk00001.dat' "$(json_field "$summary_json" 'data.get("latest_file_name", "")')" 'reindex summary should report latest block file'
  assert_eq 'blk00002.dat' "$(json_field "$summary_json" 'data.get("max_file_name", "")')" 'reindex summary should report highest on-disk block file'
  assert_eq '250' "$(json_field "$summary_json" 'data.get("latest_loaded_blocks", "")')" 'reindex summary should report most recent loaded block count'
  assert_eq '0.666667' "$(json_field "$summary_json" 'data.get("progress_ratio", "")')" 'reindex summary should derive file progress ratio'
)
pass 'reindex progress summary uses log and block file evidence'

printf '[unit] bitcoin recovery script tests complete\n'
