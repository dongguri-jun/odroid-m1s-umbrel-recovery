#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_VERSION="0.5.5"
DATA_DIR="/mnt/fullnode"
STATE_DIR="/etc/umbrel-recovery"
REQUEST_STATE_FILE="$STATE_DIR/bitcoin-chainstate-rebuild.json"

log() {
  printf '[%s] %s\n' "$1" "$2"
}

info() { log INFO "$1"; }
warn() { log WARN "$1"; }
err() { log ERROR "$1" >&2; }

usage() {
  cat <<'EOF'
ODROID M1S Umbrel — check Bitcoin chainstate rebuild status

Usage:
  sudo bash scripts/m1s-check-bitcoin-chainstate-rebuild.sh [options]

Options:
  --version      Print script version and exit.
  -h, --help     Show this help.

What this script checks:
  1. local request marker under /etc/umbrel-recovery
  2. effective bitcoin.conf / umbrel-bitcoin.conf request state
  3. recent debug.log startup evidence after the request time
  4. live RPC status via bitcoin-cli inside the Bitcoin app container, if reachable

Status order:
  - RPC is treated as the strongest live signal.
  - Logs are only used as bounded fallback hints.
  - Config/marker state means "requested", not necessarily "started".
EOF
}

parse_args() {
  [[ $# -eq 0 ]] && return 0
  if [[ $# -gt 1 ]]; then
    err "This script does not accept positional arguments or combined flags."
    usage
    exit 1
  fi

  case "$1" in
    --version)
      printf '%s\n' "$SCRIPT_VERSION"
      exit 0
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      err "Unknown argument: $1"
      usage
      exit 1
      ;;
  esac
}

require_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    err "Run this script with sudo or as root."
    exit 1
  fi
}

locate_bitcoin_config_dir() {
  python3 - "$DATA_DIR" <<'PY'
from pathlib import Path
import sys

root = Path(sys.argv[1])
if not root.exists():
    sys.exit(1)

matches = []
for path in root.rglob('bitcoin.conf'):
    try:
        rel_parts = path.relative_to(root).parts
    except ValueError:
        continue
    if len(rel_parts) > 8:
        continue
    directory = path.parent
    if (directory / 'umbrel-bitcoin.conf').is_file():
        matches.append(directory)

if not matches:
    sys.exit(1)

matches = sorted(set(matches), key=lambda p: (len(p.parts), str(p)))
for match in matches:
    print(match)
PY
}

require_single_bitcoin_config_dir() {
  local matches
  matches="$(locate_bitcoin_config_dir || true)"
  if [[ -z "$matches" ]]; then
    err "Could not find Umbrel's live Bitcoin config directory under $DATA_DIR"
    exit 1
  fi

  local count
  count="$(python3 -c 'import sys; print(len([line for line in sys.stdin.read().splitlines() if line.strip()]))' <<<"$matches")"

  if [[ "$count" -ne 1 ]]; then
    err "Found multiple candidate Bitcoin config directories under $DATA_DIR:"
    printf '%s\n' "$matches" >&2
    err "Refusing to guess."
    exit 1
  fi

  BITCOIN_CONFIG_DIR="$matches"
  BITCOIN_CONF="$BITCOIN_CONFIG_DIR/bitcoin.conf"
  UMBREL_BITCOIN_CONF="$BITCOIN_CONFIG_DIR/umbrel-bitcoin.conf"
  DEBUG_LOG="$BITCOIN_CONFIG_DIR/debug.log"
}

read_effective_settings_json() {
  python3 - "$UMBREL_BITCOIN_CONF" "$BITCOIN_CONF" <<'PY'
from pathlib import Path
import json
import sys

umbrel_conf = Path(sys.argv[1])
bitcoin_conf = Path(sys.argv[2])
managed_begin = '# m1s-bitcoin-chainstate-rebuild: begin'
managed_end = '# m1s-bitcoin-chainstate-rebuild: end'

keys = {'prune', 'reindex', 'reindex-chainstate'}
values = {key: '' for key in keys}
managed_present = False
request_present = False
includeconf_present = False


def normalize_value(raw: str) -> str:
    return raw.split('#', 1)[0].strip()


def process_kv_line(raw_line: str):
    global request_present
    stripped = raw_line.strip()
    if not stripped or stripped.startswith('#') or '=' not in stripped:
        return
    key, value = stripped.split('=', 1)
    key = key.strip().lower()
    value = normalize_value(value)
    if key in values:
        values[key] = value
    if key == 'reindex-chainstate' and value == '1':
        request_present = True

for raw in umbrel_conf.read_text(encoding='utf-8').splitlines():
    process_kv_line(raw)

for idx, raw in enumerate(bitcoin_conf.read_text(encoding='utf-8').splitlines()):
    stripped = raw.strip()
    if idx == 0 and stripped == 'includeconf=umbrel-bitcoin.conf':
        includeconf_present = True
    if stripped == managed_begin:
        managed_present = True
    process_kv_line(raw)

print(json.dumps({
    'values': values,
    'managed_present': managed_present,
    'request_present': request_present,
    'includeconf_present': includeconf_present,
}))
PY
}

json_field() {
  local json_input="$1"
  local expression="$2"
  python3 -c 'import json, sys; expr = sys.argv[1]; data = json.load(sys.stdin); value = eval(expr, {"data": data}); print("" if value is None else ("1" if isinstance(value, bool) and value else "0" if isinstance(value, bool) else value))' "$expression" <<<"$json_input"
}

read_request_state_json() {
  [[ -f "$REQUEST_STATE_FILE" ]] || return 1
  python3 - "$REQUEST_STATE_FILE" <<'PY'
from pathlib import Path
import json
import sys
print(json.dumps(json.loads(Path(sys.argv[1]).read_text(encoding='utf-8'))))
PY
}

request_state_field() {
  local expression="$1"
  if [[ -z "${REQUEST_STATE_JSON:-}" ]]; then
    printf '\n'
    return 0
  fi
  python3 -c 'import json, sys; expr = sys.argv[1]; data = json.load(sys.stdin); value = eval(expr, {"data": data}); print("" if value is None else ("1" if isinstance(value, bool) and value else "0" if isinstance(value, bool) else value))' "$expression" <<<"$REQUEST_STATE_JSON"
}

recent_chainstate_start_after_request() {
  local request_epoch="$1"
  [[ -f "$DEBUG_LOG" ]] || return 1
  python3 - "$DEBUG_LOG" "$request_epoch" <<'PY'
from pathlib import Path
import os
import sys

path = Path(sys.argv[1])
request_epoch = int(sys.argv[2])
try:
    stat = path.stat()
except FileNotFoundError:
    sys.exit(1)
if int(stat.st_mtime) < request_epoch:
    sys.exit(1)
text = path.read_text(encoding='utf-8', errors='replace')
needle = 'Initializing chainstate '
sys.exit(0 if needle in text else 1)
PY
}

locate_bitcoin_container() {
  [[ -n "${BITCOIN_CONFIG_DIR:-}" ]] || return 1
  command -v docker >/dev/null 2>&1 || return 1
  local container_name
  while IFS= read -r container_name; do
    [[ -n "$container_name" ]] || continue
    local result
    result="$(docker inspect "$container_name" 2>/dev/null | python3 -c 'import json, sys
config_dir = sys.argv[1]
try:
    payload = json.load(sys.stdin)
except json.JSONDecodeError:
    raise SystemExit(1)
if not payload:
    raise SystemExit(1)
container = payload[0]
for mount in container.get("Mounts", []):
    src = mount.get("Source") or ""
    dst = mount.get("Destination") or ""
    if not src or not dst:
        continue
    if config_dir == src or config_dir.startswith(src.rstrip("/") + "/"):
        rel = config_dir[len(src):].lstrip("/")
        inside = dst.rstrip("/")
        if rel:
            inside = f"{inside}/{rel}"
        print(container.get("Name", "").lstrip("/"))
        print(inside)
        raise SystemExit(0)
raise SystemExit(1)' "$BITCOIN_CONFIG_DIR")" || continue
    if [[ -n "$result" ]]; then
      printf '%s\n' "$result"
      return 0
    fi
  done < <(docker ps --format '{{.Names}}' 2>/dev/null)
  return 1
}

run_bitcoin_cli_rpc() {
  local method="$1"
  local locate_output
  locate_output="$(locate_bitcoin_container || true)"
  [[ -n "$locate_output" ]] || return 1
  local container_name data_dir
  container_name="$(printf '%s\n' "$locate_output" | sed -n '1p')"
  data_dir="$(printf '%s\n' "$locate_output" | sed -n '2p')"
  [[ -n "$container_name" && -n "$data_dir" ]] || return 1
  BITCOIN_CONTAINER_NAME="$container_name"
  BITCOIN_CONTAINER_DATA_DIR="$data_dir"

  local output
  if output="$(docker exec "$container_name" bitcoin-cli "-datadir=$data_dir" "$method" 2>/dev/null)"; then
    printf '%s\n' "$output"
    return 0
  fi
  if output="$(docker exec "$container_name" bitcoin-cli "-conf=$data_dir/bitcoin.conf" "$method" 2>/dev/null)"; then
    printf '%s\n' "$output"
    return 0
  fi
  if output="$(docker exec "$container_name" bitcoin-cli "$method" 2>/dev/null)"; then
    printf '%s\n' "$output"
    return 0
  fi
  return 1
}

summarize_chainstates_rpc() {
  local chainstates_json="$1"
  python3 -c 'import json, sys
payload = json.load(sys.stdin)
chainstates = payload.get("chainstates") if isinstance(payload, dict) else None
if not isinstance(chainstates, list):
    print(json.dumps({"rpc_chainstates_ok": False}))
    raise SystemExit(0)
unvalidated = [state for state in chainstates if isinstance(state, dict) and state.get("validated") is False]
progress = ""
if unvalidated:
    candidate = unvalidated[-1].get("verificationprogress")
    if candidate is not None:
        progress = str(candidate)
print(json.dumps({"rpc_chainstates_ok": True, "unvalidated_count": len(unvalidated), "has_live_validation": len(unvalidated) > 0, "progress": progress}))' <<<"$chainstates_json"
}

summarize_blockchaininfo_rpc() {
  local blockchaininfo_json="$1"
  python3 -c 'import json, sys
payload = json.load(sys.stdin)
progress = payload.get("verificationprogress", "")
ibd = payload.get("initialblockdownload", "")
print(json.dumps({"rpc_blockchaininfo_ok": True, "verificationprogress": "" if progress == "" else str(progress), "initialblockdownload": bool(ibd) if ibd != "" else False}))' <<<"$blockchaininfo_json"
}

format_progress_percent() {
  local raw="$1"
  python3 - "$raw" <<'PY'
import sys
raw = sys.argv[1]
if not raw:
    print('unavailable')
    raise SystemExit(0)
value = float(raw) * 100.0
print(f'{value:.2f}%')
PY
}

resolve_rebuild_state() {
  local request_evidence="$1"
  local rpc_rebuild="$2"
  local log_started="$3"
  local live_validation_without_request="$4"

  if [[ "$rpc_rebuild" -eq 1 && "$request_evidence" -eq 1 ]]; then
    printf 'rebuild-in-progress\n'
    return 0
  fi
  if [[ "$log_started" -eq 1 && "$request_evidence" -eq 1 ]]; then
    printf 'rebuild-started-progress-unavailable\n'
    return 0
  fi
  if [[ "$request_evidence" -eq 1 ]]; then
    printf 'requested-awaiting-restart\n'
    return 0
  fi
  if [[ "$live_validation_without_request" -eq 1 ]]; then
    printf 'live-validation-unconfirmed\n'
    return 0
  fi
  printf 'no-request-detected\n'
}

print_human_state() {
  case "$1" in
    rebuild-in-progress)
      printf 'Current status: rebuild in progress\n'
      ;;
    rebuild-started-progress-unavailable)
      printf 'Current status: rebuild appears to have started, but live progress is unavailable\n'
      ;;
    requested-awaiting-restart)
      printf 'Current status: request recorded, restart not yet confirmed\n'
      ;;
    live-validation-unconfirmed)
      printf 'Current status: live validation activity detected, but this script cannot prove it is the requested chainstate rebuild\n'
      ;;
    *)
      printf 'Current status: no active chainstate rebuild request detected\n'
      ;;
  esac
}

main() {
  parse_args "$@"
  require_root
  require_single_bitcoin_config_dir

  local settings_json
  settings_json="$(read_effective_settings_json)"

  REQUEST_STATE_JSON="$(read_request_state_json || true)"
  local marker_present=0 request_epoch="0"
  if [[ -n "$REQUEST_STATE_JSON" ]]; then
    marker_present=1
    request_epoch="$(request_state_field 'data.get("requested_at_epoch", 0)')"
    [[ -n "$request_epoch" ]] || request_epoch="0"
  fi

  local config_request_present managed_present includeconf_present
  config_request_present="$(json_field "$settings_json" 'data["request_present"]')"
  managed_present="$(json_field "$settings_json" 'data["managed_present"]')"
  includeconf_present="$(json_field "$settings_json" 'data["includeconf_present"]')"

  local request_evidence=0
  if [[ "$marker_present" -eq 1 || "$config_request_present" -eq 1 ]]; then
    request_evidence=1
  fi

  local log_started=0
  if [[ "$request_epoch" =~ ^[0-9]+$ ]] && (( request_epoch > 0 )) && recent_chainstate_start_after_request "$request_epoch"; then
    log_started=1
  fi

  local rpc_chainstates_ok=0 rpc_rebuild=0 rpc_progress="" rpc_blockchaininfo_ok=0 rpc_ibd=0
  local live_validation_without_request=0
  local chainstates_raw blockchaininfo_raw chainstates_summary blockchain_summary

  if chainstates_raw="$(run_bitcoin_cli_rpc getchainstates 2>/dev/null)"; then
    chainstates_summary="$(summarize_chainstates_rpc "$chainstates_raw")"
    rpc_chainstates_ok="$(json_field "$chainstates_summary" 'data.get("rpc_chainstates_ok", False)')"
    rpc_rebuild="$(json_field "$chainstates_summary" '1 if data.get("has_live_validation") else 0')"
    rpc_progress="$(json_field "$chainstates_summary" 'data.get("progress", "")')"
  fi

  if blockchaininfo_raw="$(run_bitcoin_cli_rpc getblockchaininfo 2>/dev/null)"; then
    blockchain_summary="$(summarize_blockchaininfo_rpc "$blockchaininfo_raw")"
    rpc_blockchaininfo_ok="$(json_field "$blockchain_summary" 'data.get("rpc_blockchaininfo_ok", False)')"
    if [[ -z "$rpc_progress" ]]; then
      rpc_progress="$(json_field "$blockchain_summary" 'data.get("verificationprogress", "")')"
    fi
    rpc_ibd="$(json_field "$blockchain_summary" '1 if data.get("initialblockdownload") else 0')"
  fi

  if [[ "$request_evidence" -eq 0 && ( "$rpc_rebuild" -eq 1 || "$rpc_ibd" -eq 1 ) ]]; then
    live_validation_without_request=1
  fi

  local state
  state="$(resolve_rebuild_state "$request_evidence" "$rpc_rebuild" "$log_started" "$live_validation_without_request")"

  echo
  echo "=== ODROID M1S Bitcoin chainstate rebuild status ==="
  echo "Script version:           $SCRIPT_VERSION"
  echo "Bitcoin config dir:       $BITCOIN_CONFIG_DIR"
  echo "bitcoin.conf:             $BITCOIN_CONF"
  echo "umbrel-bitcoin.conf:      $UMBREL_BITCOIN_CONF"
  echo "debug.log:                $DEBUG_LOG"
  echo "Request state file:       $REQUEST_STATE_FILE"
  echo "Request marker present:   $marker_present"
  if [[ "$marker_present" -eq 1 ]]; then
    echo "Requested at:             $(request_state_field 'data.get("requested_at_iso", "")')"
  fi
  echo "Include banner present:   $includeconf_present"
  echo "Config request present:   $config_request_present"
  echo "Managed request block:    $managed_present"
  echo "Recent startup evidence:  $log_started"
  echo "RPC getchainstates:       $rpc_chainstates_ok"
  echo "RPC getblockchaininfo:    $rpc_blockchaininfo_ok"
  if [[ -n "${BITCOIN_CONTAINER_NAME:-}" ]]; then
    echo "Bitcoin container:        $BITCOIN_CONTAINER_NAME"
    echo "Container data dir:       $BITCOIN_CONTAINER_DATA_DIR"
  fi
  if [[ -n "$rpc_progress" ]]; then
    echo "Approx progress:          $(format_progress_percent "$rpc_progress")"
  else
    echo "Approx progress:          unavailable"
  fi
  echo
  print_human_state "$state"
  echo

  case "$state" in
    rebuild-in-progress)
      echo "Use this same command again later to watch the live progress estimate."
      echo "Do not clear the request yet if you want to avoid any ambiguity during the current run."
      ;;
    rebuild-started-progress-unavailable)
      echo "The node appears to have started the rebuild, but live RPC progress is not reachable yet."
      echo "Retry this command after the Bitcoin app settles a bit more."
      ;;
    requested-awaiting-restart)
      echo "The request exists in config/marker state, but this script cannot prove that the Bitcoin app has consumed it yet."
      echo "Restart the Bitcoin app once from the Umbrel web UI, then run this check again."
      ;;
    live-validation-unconfirmed)
      echo "The node is doing live validation work, but there is no matching local request marker or config request."
      echo "This could be normal sync or another validation path, so this script stays conservative."
      ;;
    no-request-detected)
      echo "No local request marker or effective reindex-chainstate request is visible right now."
      echo "If you need to request one, run:"
      echo "  sudo bash scripts/m1s-request-bitcoin-chainstate-rebuild.sh"
      ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
