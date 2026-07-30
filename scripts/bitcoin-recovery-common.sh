#!/usr/bin/env bash
set -Eeuo pipefail

: "${DATA_DIR:=/mnt/fullnode}"
: "${STATE_DIR:=/etc/umbrel-recovery}"
: "${RECOVERY_STATE_FILE:=$STATE_DIR/bitcoin-recovery.json}"
: "${DRY_RUN:=0}"

# shellcheck source=scripts/m1s-support-policy.sh
source "$(dirname "${BASH_SOURCE[0]}")/m1s-support-policy.sh"

MANAGED_BEGIN="# m1s-bitcoin-recovery: begin"
MANAGED_END="# m1s-bitcoin-recovery: end"

log() {
  printf '[%s] %s\n' "$1" "$2"
}

info() { log INFO "$1"; }
warn() { log WARN "$1"; }
err() { log ERROR "$1" >&2; }

run_cmd() {
  if [[ "$DRY_RUN" -eq 1 ]]; then
    printf '[DRY-RUN]'
    for arg in "$@"; do
      printf ' %q' "$arg"
    done
    printf '\n'
    return 0
  fi
  "$@"
}

require_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    err "Run this script with sudo or as root."
    exit 1
  fi
}

mode_display_name() {
  case "$1" in
    chainstate-rebuild) printf 'chainstate rebuild\n' ;;
    reindex) printf 'reindex\n' ;;
    full-resync|full-download) printf 'full download\n' ;;
    *) printf '%s\n' "$1" ;;
  esac
}

mode_request_line() {
  case "$1" in
    chainstate-rebuild) printf 'reindex-chainstate=1\n' ;;
    reindex) printf 'reindex=1\n' ;;
    full-resync) printf '\n' ;;
    *) return 1 ;;
  esac
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
    err "Expected a directory containing both bitcoin.conf and umbrel-bitcoin.conf."
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
  BITCOIN_APP_DATA_DIR="$(dirname "$BITCOIN_CONFIG_DIR")"
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
managed_begin = '# m1s-bitcoin-recovery: begin'
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
    if key in {'reindex', 'reindex-chainstate'} and value == '1':
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

value_is_truthy() {
  local raw="${1,,}"
  [[ -n "$raw" && "$raw" != "0" && "$raw" != "false" && "$raw" != "no" ]]
}

require_safe_recovery_mode() {
  local mode="$1"
  local settings_json="$2"
  local prune_value reindex_value reindex_chainstate_value
  prune_value="$(json_field "$settings_json" 'data["values"]["prune"]')"
  reindex_value="$(json_field "$settings_json" 'data["values"]["reindex"]')"
  reindex_chainstate_value="$(json_field "$settings_json" 'data["values"]["reindex-chainstate"]')"

  if [[ "$mode" == "chainstate-rebuild" ]] && value_is_truthy "$prune_value"; then
    err "Effective Bitcoin config still enables prune=$prune_value"
    err "Bitcoin Core rejects reindex-chainstate in prune mode. Use full resync instead."
    exit 1
  fi

  case "$mode" in
    chainstate-rebuild)
      if value_is_truthy "$reindex_value"; then
        err "Effective Bitcoin config already has reindex=$reindex_value"
        err "Refusing to combine reindex and reindex-chainstate requests."
        exit 1
      fi
      ;;
    reindex)
      if value_is_truthy "$reindex_chainstate_value"; then
        err "Effective Bitcoin config already has reindex-chainstate=$reindex_chainstate_value"
        err "Refusing to combine chainstate rebuild and reindex requests."
        exit 1
      fi
      ;;
  esac
}

ensure_state_dir() {
  run_cmd mkdir -p "$STATE_DIR"
}

backup_file() {
  local file="$1"
  local backup_path
  backup_path="$file.backup.$(date +%s)"
  run_cmd cp -a "$file" "$backup_path"
  info "Backup written: $backup_path"
}

write_request_block() {
  local request_line="$1"
  python3 - "$BITCOIN_CONF" "$MANAGED_BEGIN" "$MANAGED_END" "$request_line" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
managed_begin = sys.argv[2]
managed_end = sys.argv[3]
request_line = sys.argv[4]
text = path.read_text(encoding='utf-8')
lines = text.splitlines()
output = []
in_managed = False
found_request = False

for line in lines:
    stripped = line.strip()
    if stripped == managed_begin:
        in_managed = True
        continue
    if stripped == managed_end:
        in_managed = False
        continue
    if in_managed:
        continue
    if request_line and stripped == request_line:
        found_request = True
    output.append(line)

status = 'added'
if request_line and found_request:
    status = 'already-present'
elif request_line:
    while output and output[-1] == '':
        output.pop()
    if output:
        output.append('')
    output.extend([
        managed_begin,
        request_line,
        managed_end,
    ])
else:
    status = 'not-needed'

path.write_text('\n'.join(output) + '\n', encoding='utf-8')
print(status)
PY
}

clear_managed_request_block() {
  python3 - "$BITCOIN_CONF" "$MANAGED_BEGIN" "$MANAGED_END" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
managed_begin = sys.argv[2]
managed_end = sys.argv[3]
text = path.read_text(encoding='utf-8')
lines = text.splitlines()
output = []
in_managed = False
removed = False

for line in lines:
    stripped = line.strip()
    if stripped == managed_begin:
        in_managed = True
        removed = True
        continue
    if stripped == managed_end:
        in_managed = False
        continue
    if in_managed:
        continue
    output.append(line)

while len(output) >= 2 and output[-1] == '' and output[-2] == '':
    output.pop()

path.write_text('\n'.join(output) + '\n', encoding='utf-8')
print('removed' if removed else 'not-present')
PY
}

write_recovery_state() {
  local mode="$1"
  local request_line="$2"
  local source_script="$3"
  if [[ "$DRY_RUN" -eq 1 ]]; then
    echo "[DRY-RUN] write $RECOVERY_STATE_FILE"
    return 0
  fi

  python3 - "$RECOVERY_STATE_FILE" "$mode" "$BITCOIN_CONFIG_DIR" "$BITCOIN_CONF" "$request_line" "$source_script" <<'PY'
from pathlib import Path
import datetime as dt
import json
import time
import sys

path = Path(sys.argv[1])
mode = sys.argv[2]
config_dir = sys.argv[3]
bitcoin_conf = sys.argv[4]
request_line = sys.argv[5]
source_script = sys.argv[6]
path.parent.mkdir(parents=True, exist_ok=True)
now = dt.datetime.now(dt.timezone.utc)
payload = {
    'active_request': True,
    'mode': mode,
    'requested_at_epoch': int(time.time()),
    'requested_at_iso': now.isoformat(),
    'config_dir': config_dir,
    'bitcoin_conf': bitcoin_conf,
    'request': request_line,
    'restart_attempted_at_epoch': None,
    'restart_attempted_at_iso': None,
    'restart_succeeded': False,
    'request_consumed_at_epoch': None,
    'request_consumed_at_iso': None,
    'last_observed_state': 'requested',
    'data_reset_performed': False,
    'source': source_script,
}
path.write_text(json.dumps(payload, indent=2, sort_keys=True) + '\n', encoding='utf-8')
PY
}

update_recovery_state_restart() {
  local restart_succeeded="$1"
  if [[ "$DRY_RUN" -eq 1 ]]; then
    echo "[DRY-RUN] update $RECOVERY_STATE_FILE restart_succeeded=$restart_succeeded"
    return 0
  fi

  python3 - "$RECOVERY_STATE_FILE" "$restart_succeeded" <<'PY'
from pathlib import Path
import datetime as dt
import json
import time
import sys

path = Path(sys.argv[1])
restart_succeeded = sys.argv[2] == '1'
if not path.exists():
    raise SystemExit(0)
payload = json.loads(path.read_text(encoding='utf-8'))
now = dt.datetime.now(dt.timezone.utc)
payload['restart_attempted_at_epoch'] = int(time.time())
payload['restart_attempted_at_iso'] = now.isoformat()
payload['restart_succeeded'] = restart_succeeded
payload['last_observed_state'] = 'restart-sent' if restart_succeeded else 'restart-failed'
path.write_text(json.dumps(payload, indent=2, sort_keys=True) + '\n', encoding='utf-8')
PY
}

mark_data_reset_performed() {
  if [[ "$DRY_RUN" -eq 1 ]]; then
    echo "[DRY-RUN] update $RECOVERY_STATE_FILE data_reset_performed=true"
    return 0
  fi

  python3 - "$RECOVERY_STATE_FILE" <<'PY'
from pathlib import Path
import json
import sys

path = Path(sys.argv[1])
if not path.exists():
    raise SystemExit(0)
payload = json.loads(path.read_text(encoding='utf-8'))
payload['data_reset_performed'] = True
payload['last_observed_state'] = 'data-reset'
path.write_text(json.dumps(payload, indent=2, sort_keys=True) + '\n', encoding='utf-8')
PY
}

read_recovery_state_json() {
  [[ -f "$RECOVERY_STATE_FILE" ]] || return 1
  python3 - "$RECOVERY_STATE_FILE" <<'PY'
from pathlib import Path
import json
import sys
print(json.dumps(json.loads(Path(sys.argv[1]).read_text(encoding='utf-8'))))
PY
}

recovery_state_field() {
  local expression="$1"
  if [[ -z "${RECOVERY_STATE_JSON:-}" ]]; then
    printf '\n'
    return 0
  fi
  python3 -c 'import json, sys; expr = sys.argv[1]; data = json.load(sys.stdin); value = eval(expr, {"data": data}); print("" if value is None else ("1" if isinstance(value, bool) and value else "0" if isinstance(value, bool) else value))' "$expression" <<<"$RECOVERY_STATE_JSON"
}

mark_recovery_consumed() {
  local observed_state="$1"
  python3 - "$RECOVERY_STATE_FILE" "$observed_state" <<'PY'
from pathlib import Path
import datetime as dt
import json
import time
import sys

path = Path(sys.argv[1])
observed_state = sys.argv[2]
if not path.exists():
    raise SystemExit(0)
payload = json.loads(path.read_text(encoding='utf-8'))
now = dt.datetime.now(dt.timezone.utc)
payload['active_request'] = False
payload['request_consumed_at_epoch'] = int(time.time())
payload['request_consumed_at_iso'] = now.isoformat()
payload['last_observed_state'] = observed_state
path.write_text(json.dumps(payload, indent=2, sort_keys=True) + '\n', encoding='utf-8')
PY
}

record_last_observed_state() {
  local observed_state="$1"
  [[ -f "$RECOVERY_STATE_FILE" ]] || return 0
  python3 - "$RECOVERY_STATE_FILE" "$observed_state" <<'PY'
from pathlib import Path
import json
import sys

path = Path(sys.argv[1])
observed_state = sys.argv[2]
payload = json.loads(path.read_text(encoding='utf-8'))
payload['last_observed_state'] = observed_state
path.write_text(json.dumps(payload, indent=2, sort_keys=True) + '\n', encoding='utf-8')
PY
}

locate_bitcoin_container() {
  command -v docker >/dev/null 2>&1 || return 1
  local container_name
  while IFS= read -r container_name; do
    [[ -n "$container_name" ]] || continue
    local result
    result="$(docker inspect "$container_name" 2>/dev/null | python3 -c 'import json, os, sys
app_data_dir = sys.argv[1]
config_dir = sys.argv[2]
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
    try:
        if not os.path.samefile(src, app_data_dir):
            continue
    except OSError:
        continue
    rel = os.path.relpath(config_dir, app_data_dir)
    if rel == os.pardir or rel.startswith(os.pardir + os.sep):
        continue
    inside = dst.rstrip("/")
    if rel:
        inside = f"{inside}/{rel}"
    print(container.get("Name", "").lstrip("/"))
    print(inside)
    raise SystemExit(0)
raise SystemExit(1)' "$BITCOIN_APP_DATA_DIR" "$BITCOIN_CONFIG_DIR")" || continue
    if [[ -n "$result" ]]; then
      printf '%s\n' "$result"
      return 0
    fi
  done < <(docker ps --format '{{.Names}}' 2>/dev/null)
  return 1
}

wait_for_container_running() {
  local container_name="$1"
  local attempts=30
  local delay=2
  local state
  local i

  for ((i=1; i<=attempts; i++)); do
    state="$(docker inspect --format='{{.State.Status}}' "$container_name" 2>/dev/null || true)"
    if [[ "$state" == "running" ]]; then
      return 0
    fi
    sleep "$delay"
  done
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

recent_recovery_start_after_request() {
  local request_epoch="$1"
  [[ -f "$DEBUG_LOG" ]] || return 1
  python3 - "$DEBUG_LOG" "$request_epoch" <<'PY'
from pathlib import Path
import datetime as dt
import re
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
marker = 'Initializing chainstate '
for line in reversed(text.splitlines()):
    if marker not in line:
        continue
    match = re.match(r'^(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2})Z', line)
    if not match:
        continue
    try:
        ts = dt.datetime.strptime(match.group(1), '%Y-%m-%dT%H:%M:%S').replace(tzinfo=dt.timezone.utc)
    except ValueError:
        continue
    if int(ts.timestamp()) >= request_epoch:
        sys.exit(0)
sys.exit(1)
PY
}

summarize_reindex_log_progress() {
  local request_epoch="$1"
  local blocks_dir="$BITCOIN_CONFIG_DIR/blocks"
  [[ -f "$DEBUG_LOG" ]] || return 1
  python3 - "$DEBUG_LOG" "$request_epoch" "$blocks_dir" <<'PY'
from pathlib import Path
import datetime as dt
import json
import re
import sys

debug_log = Path(sys.argv[1])
request_epoch = int(sys.argv[2])
blocks_dir = Path(sys.argv[3])

timestamp_re = re.compile(r'^(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2})Z')
reindex_re = re.compile(r'Reindexing block file (?P<name>blk(?P<index>\d{5})\.dat)(?: \((?P<percent>\d+(?:\.\d+)?)% complete\))?\.\.\.')
loaded_re = re.compile(r'Loaded (\d+) blocks from external file')

def parse_ts(line: str):
    match = timestamp_re.match(line)
    if not match:
        return None
    try:
        return dt.datetime.strptime(match.group(1), '%Y-%m-%dT%H:%M:%S').replace(tzinfo=dt.timezone.utc)
    except ValueError:
        return None

try:
    text = debug_log.read_text(encoding='utf-8', errors='replace')
except FileNotFoundError:
    raise SystemExit(1)

latest_file_name = ''
latest_file_index = ''
latest_file_epoch = ''
latest_loaded_blocks = ''
latest_reported_percent = ''

for line in text.splitlines():
    ts = parse_ts(line)
    if ts is not None and request_epoch > 0 and int(ts.timestamp()) < request_epoch:
        continue
    reindex_match = reindex_re.search(line)
    if reindex_match:
        latest_file_name = reindex_match.group('name')
        latest_file_index = reindex_match.group('index')
        latest_reported_percent = reindex_match.group('percent') or ''
        latest_loaded_blocks = ''
        if ts is not None:
            latest_file_epoch = str(int(ts.timestamp()))
        continue
    if latest_file_name:
        loaded_match = loaded_re.search(line)
        if loaded_match:
            latest_loaded_blocks = loaded_match.group(1)

max_file_name = ''
max_file_index = ''
if blocks_dir.is_dir():
    block_files = sorted(blocks_dir.glob('blk*.dat'))
    if block_files:
        max_file = max(block_files, key=lambda p: p.name)
        max_file_name = max_file.name
        max_file_index = max_file.name[3:8]

progress_ratio = ''
if latest_reported_percent:
    progress_ratio = f'{float(latest_reported_percent) / 100.0:.6f}'
elif latest_file_index and max_file_index:
    current = int(latest_file_index)
    maximum = int(max_file_index)
    if maximum >= 0:
        progress_ratio = f'{(current + 1) / (maximum + 1):.6f}'

print(json.dumps({
    'latest_file_name': latest_file_name,
    'latest_file_index': latest_file_index,
    'latest_file_epoch': latest_file_epoch,
    'latest_loaded_blocks': latest_loaded_blocks,
    'max_file_name': max_file_name,
    'max_file_index': max_file_index,
    'progress_ratio': progress_ratio,
}))
PY
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
blocks = payload.get("blocks", "")
headers = payload.get("headers", "")
print(json.dumps({"rpc_blockchaininfo_ok": True, "verificationprogress": "" if progress == "" else str(progress), "initialblockdownload": bool(ibd) if ibd != "" else False, "blocks": blocks, "headers": headers}))' <<<"$blockchaininfo_json"
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

assert_full_resync_delete_target_safe() {
  local target="$1"
  local target_real config_root_real

  config_root_real="$(realpath -m -- "$BITCOIN_CONFIG_DIR")"
  target_real="$(realpath -m -- "$target")"

  case "$target_real" in
    "$config_root_real"/*)
      ;;
    *)
      err "Refusing to delete Bitcoin data outside config dir: $target_real"
      err "Expected path under: $config_root_real"
      return 1
      ;;
  esac

  case "$(basename "$target_real")" in
    blocks|chainstate|indexes)
      ;;
    *)
      err "Refusing to delete unexpected Bitcoin full-resync target: $target_real"
      return 1
      ;;
  esac
}

perform_full_resync_reset() {
  local targets=(
    "$BITCOIN_CONFIG_DIR/blocks"
    "$BITCOIN_CONFIG_DIR/chainstate"
    "$BITCOIN_CONFIG_DIR/indexes"
  )
  local target
  for target in "${targets[@]}"; do
    assert_full_resync_delete_target_safe "$target"
    if [[ -e "$target" ]]; then
      run_cmd rm -rf -- "$target"
    fi
  done
}

print_start_status() {
  local mode="$1"
  local settings_json="$2"
  echo
  echo "=== ODROID M1S Bitcoin $(mode_display_name "$mode") start ==="
  echo "Script version:        ${SCRIPT_VERSION:-unknown}"
  echo "Bitcoin config dir:    $BITCOIN_CONFIG_DIR"
  echo "bitcoin.conf:          $BITCOIN_CONF"
  echo "umbrel-bitcoin.conf:   $UMBREL_BITCOIN_CONF"
  echo "debug.log:             $DEBUG_LOG"
  echo "State file:            $RECOVERY_STATE_FILE"
  echo "Dry run:               $DRY_RUN"
  echo
  echo "Effective config values:"
  echo "  prune:               $(json_field "$settings_json" 'data["values"]["prune"]')"
  echo "  reindex:             $(json_field "$settings_json" 'data["values"]["reindex"]')"
  echo "  reindex-chainstate:  $(json_field "$settings_json" 'data["values"]["reindex-chainstate"]')"
  echo
}

run_recovery_start() {
  local mode="$1"
  local source_script="$2"
  m1s_report_host_support
  require_root
  require_single_bitcoin_config_dir

  if [[ ! -f "$BITCOIN_CONF" || ! -f "$UMBREL_BITCOIN_CONF" ]]; then
    err "Expected both bitcoin.conf and umbrel-bitcoin.conf in $BITCOIN_CONFIG_DIR"
    exit 1
  fi

  local settings_json request_line locate_output container_name container_data_dir container_state write_status
  settings_json="$(read_effective_settings_json)"
  print_start_status "$mode" "$settings_json"
  require_safe_recovery_mode "$mode" "$settings_json"
  ensure_state_dir
  backup_file "$BITCOIN_CONF"
  request_line="$(mode_request_line "$mode")"

  if [[ "$DRY_RUN" -eq 1 ]]; then
    if [[ -n "$request_line" ]]; then
      if [[ "$request_line" == "reindex=1" && "$(json_field "$settings_json" 'data["values"]["reindex"]')" == "1" ]]; then
        write_status="already-present"
      elif [[ "$request_line" == "reindex-chainstate=1" && "$(json_field "$settings_json" 'data["values"]["reindex-chainstate"]')" == "1" ]]; then
        write_status="already-present"
      else
        write_status="would-add"
      fi
    else
      write_status="would-reset-data"
    fi
  else
    if [[ -n "$request_line" ]]; then
      write_status="$(write_request_block "$request_line")"
    else
      write_status="$(clear_managed_request_block)"
    fi
    write_recovery_state "$mode" "$request_line" "$source_script"
  fi

  locate_output="$(locate_bitcoin_container || true)"
  if [[ -z "$locate_output" ]]; then
    update_recovery_state_restart 0
    err "Could not locate the live Bitcoin app container from host Docker mounts."
    err "The recovery state was recorded, but the app restart could not be automated."
    err "If you are in Umbrel web UI Terminal, confirm you already entered host shell with: sudo nsenter -t 1 -m -u -i -n -p -- bash"
    exit 1
  fi

  container_name="$(printf '%s\n' "$locate_output" | sed -n '1p')"
  container_data_dir="$(printf '%s\n' "$locate_output" | sed -n '2p')"

  echo "Write result: $write_status"
  echo "Recovery mode: $(mode_display_name "$mode")"
  echo "Bitcoin container: $container_name"
  echo "Container data dir: $container_data_dir"

  if [[ "$DRY_RUN" -eq 1 ]]; then
    if [[ "$mode" == "full-resync" ]]; then
      echo "[DRY-RUN] docker stop $container_name"
      echo "[DRY-RUN] rm -rf $BITCOIN_CONFIG_DIR/blocks $BITCOIN_CONFIG_DIR/chainstate $BITCOIN_CONFIG_DIR/indexes"
      echo "[DRY-RUN] docker start $container_name"
      mark_data_reset_performed
    else
      echo "[DRY-RUN] docker restart $container_name"
    fi
    update_recovery_state_restart 1
    echo
    echo "[DRY-RUN] Recovery flow prepared."
    echo "Next step: run sudo bash scripts/m1s-check-bitcoin-recovery-status.sh"
    return 0
  fi

  if [[ "$mode" == "full-resync" ]]; then
    container_state="$(docker inspect --format='{{.State.Status}}' "$container_name" 2>/dev/null || true)"
    if [[ "$container_state" == "running" ]]; then
      info "Stopping Bitcoin app container before full resync reset: $container_name"
      docker stop "$container_name" >/dev/null
    fi
    info "Removing Bitcoin block/index/chainstate data for full resync"
    perform_full_resync_reset
    mark_data_reset_performed
    info "Starting Bitcoin app container: $container_name"
    docker start "$container_name" >/dev/null
  else
    info "Restarting Bitcoin app container: $container_name"
    docker restart "$container_name" >/dev/null
  fi

  if ! wait_for_container_running "$container_name"; then
    update_recovery_state_restart 0
    err "Bitcoin container did not return to running state after $( [[ "$mode" == "full-resync" ]] && printf 'start' || printf 'restart' )."
    err "Run the health-check command for more detail: sudo bash scripts/m1s-check-bitcoin-recovery-status.sh"
    exit 1
  fi

  update_recovery_state_restart 1
  echo
  echo "$(mode_display_name "$mode") request recorded and Bitcoin app $( [[ "$mode" == "full-resync" ]] && printf 'start' || printf 'restart' ) sent."
  echo "Now confirm progress with:"
  echo "  sudo bash scripts/m1s-check-bitcoin-recovery-status.sh"
}

infer_recovery_mode_from_log() {
  local request_epoch="${1:-0}"
  [[ -f "$DEBUG_LOG" ]] || return 1
  python3 - "$DEBUG_LOG" "$request_epoch" <<'PY'
from pathlib import Path
import datetime as dt
import re
import sys

path = Path(sys.argv[1])
request_epoch = int(sys.argv[2])
text = path.read_text(encoding='utf-8', errors='replace')
mode = None
for line in reversed(text.splitlines()):
    ts_match = re.match(r'^(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2})Z', line)
    if ts_match and request_epoch > 0:
        try:
            ts = dt.datetime.strptime(ts_match.group(1), '%Y-%m-%dT%H:%M:%S').replace(tzinfo=dt.timezone.utc)
        except ValueError:
            ts = None
        if ts is not None and int(ts.timestamp()) < request_epoch:
            break
    if 'Config file arg: reindex-chainstate="1"' in line:
        mode = 'chainstate-rebuild'
        break
    if 'Config file arg: reindex="1"' in line:
        mode = 'reindex'
        break
if mode:
    print(mode)
    raise SystemExit(0)
raise SystemExit(1)
PY
}

resolve_recovery_mode() {
  local state_mode="$1"
  local config_reindex="$2"
  local config_reindex_chainstate="$3"
  local log_mode="${4:-}"
  local runtime_mode="${5:-}"

  if [[ -n "$state_mode" && "$state_mode" != "unknown" ]]; then
    printf '%s\n' "$state_mode"
    return 0
  fi
  if [[ "$config_reindex_chainstate" == "1" ]]; then
    printf 'chainstate-rebuild\n'
    return 0
  fi
  if [[ "$config_reindex" == "1" ]]; then
    printf 'reindex\n'
    return 0
  fi
  if [[ -n "$log_mode" ]]; then
    printf '%s\n' "$log_mode"
    return 0
  fi
  if [[ -n "$runtime_mode" ]]; then
    printf '%s\n' "$runtime_mode"
    return 0
  fi
  printf 'unknown\n'
}

resolve_recovery_status() {
  local active_request="$1"
  local live_recovery_evidence="$2"
  local log_started="$3"
  local had_prior_request="$4"
  local mode_known="$5"

  if [[ "$live_recovery_evidence" -eq 1 ]]; then
    printf 'recovery-in-progress\n'
    return 0
  fi
  if [[ "$log_started" -eq 1 && ( "$active_request" -eq 1 || "$mode_known" -eq 1 ) ]]; then
    printf 'recovery-started-progress-unavailable\n'
    return 0
  fi
  if [[ "$active_request" -eq 1 ]]; then
    printf 'request-recorded-restart-not-confirmed\n'
    return 0
  fi
  if [[ "$had_prior_request" -eq 1 ]]; then
    printf 'recovery-not-currently-detected\n'
    return 0
  fi
  if [[ "$mode_known" -eq 1 ]]; then
    printf 'recovery-inferred-from-runtime\n'
    return 0
  fi
  printf 'no-recovery-detected\n'
}

print_human_status() {
  local status="$1"
  local mode="$2"
  case "$status" in
    recovery-in-progress)
      if [[ "$mode" == "full-resync" || "$mode" == "full-download" ]]; then
        printf 'Current status: full download in progress\n'
      else
        printf 'Current status: recovery in progress\n'
      fi
      ;;
    recovery-started-progress-unavailable)
      printf 'Current status: recovery appears to have started, but live progress is unavailable\n'
      ;;
    request-recorded-restart-not-confirmed)
      printf 'Current status: recovery request recorded, restart not yet confirmed\n'
      ;;
    recovery-not-currently-detected)
      printf 'Current status: no active recovery is visible right now\n'
      ;;
    recovery-inferred-from-runtime)
      if [[ "$mode" == "full-resync" || "$mode" == "full-download" ]]; then
        printf 'Current status: full download appears to be in progress based on live runtime evidence\n'
      else
        printf 'Current status: recovery appears to be in progress based on live runtime evidence\n'
      fi
      ;;
    *)
      printf 'Current status: no active recovery request detected\n'
      ;;
  esac
}

resolve_storage_parent_device() {
  local source="$1"
  [[ "$source" == /dev/* ]] || return 1

  local device parent
  device="$(readlink -f "$source" 2>/dev/null || printf '%s\n' "$source")"
  [[ -b "$device" ]] || return 1

  parent="$(lsblk -no PKNAME "$device" 2>/dev/null | head -n 1 || true)"
  if [[ -n "$parent" ]]; then
    printf '/dev/%s\n' "$parent"
    return 0
  fi

  printf '%s\n' "$device"
}

print_indented_command_output() {
  local unavailable_message="$1"
  shift

  local output
  output="$({ "$@"; } 2>/dev/null || true)"
  if [[ -n "$output" ]]; then
    printf '%s\n' "$output" | sed 's/^/  /'
  else
    echo "  $unavailable_message"
  fi
}

print_recent_storage_kernel_hints() {
  local pattern='nvme.*(timeout|reset|abort|failed|error|critical|CSTS|Device not ready)|EXT4-fs (error|warning)|I/O error|i/o error|blk_update|buffer I/O|critical medium error|failed command'
  local output=""

  if command -v journalctl >/dev/null 2>&1; then
    output="$({ journalctl -k -n 500 --no-pager 2>/dev/null | grep -Ei "$pattern" | tail -25; } 2>/dev/null || true)"
  fi

  if [[ -z "$output" ]]; then
    output="$({ dmesg -T 2>/dev/null | grep -Ei "$pattern" | tail -25; } 2>/dev/null || true)"
  fi

  if [[ -n "$output" ]]; then
    printf '%s\n' "$output" | sed 's/^/  /'
  else
    echo '  none visible in recent kernel logs, or kernel log access is restricted'
  fi
}

print_recent_bitcoin_error_hints() {
  local pattern='Fatal|EXCEPTION|LevelDB|Input/output error|I/O error|Corruption|txindex|chainstate|Error|error|Warning|warning'
  if [[ ! -f "$DEBUG_LOG" ]]; then
    echo '  debug.log unavailable'
    return 0
  fi

  local output
  output="$({ tail -400 "$DEBUG_LOG" 2>/dev/null | grep -Ei "$pattern" | tail -30; } 2>/dev/null || true)"
  if [[ -n "$output" ]]; then
    printf '%s\n' "$output" | sed 's/^/  /'
  else
    echo '  none visible in recent Bitcoin debug.log tail'
  fi
}

print_bitcoin_container_diagnostics() {
  local locate_output container_name container_state container_status
  locate_output="$(locate_bitcoin_container || true)"
  if [[ -z "$locate_output" ]]; then
    echo 'Bitcoin container:        unavailable'
    echo 'Container state:          unavailable'
    return 0
  fi

  local container_data_dir
  container_name="$(printf '%s\n' "$locate_output" | sed -n '1p')"
  container_data_dir="$(printf '%s\n' "$locate_output" | sed -n '2p')"
  container_state="$(docker inspect --format='{{.State.Status}}' "$container_name" 2>/dev/null || true)"
  container_status="$(docker inspect --format='{{.State.Health.Status}}' "$container_name" 2>/dev/null || true)"

  echo "Bitcoin container:        ${container_name:-unavailable}"
  echo "Container data dir:       ${container_data_dir:-unavailable}"
  echo "Container state:          ${container_state:-unavailable}"
  if [[ -n "$container_status" && "$container_status" != "<no value>" ]]; then
    echo "Container health:         $container_status"
  fi
}

print_system_diagnostics() {
  echo "=== System diagnostics ==="
  echo "Uptime and load:"
  print_indented_command_output 'uptime output unavailable' uptime
  echo

  echo "Memory usage:"
  print_indented_command_output 'free output unavailable' free -h
  echo

  echo "Active swap:"
  print_indented_command_output 'swapon output unavailable or no active swap' swapon --show
  echo

  echo "Docker service state:"
  if command -v systemctl >/dev/null 2>&1; then
    print_indented_command_output 'docker service state unavailable' systemctl --no-pager --plain is-active docker.service docker.socket
  else
    echo '  systemctl unavailable'
  fi
  echo

  echo "Recent NVMe timeout snapshots:"
  if [[ -d /var/lib/nvme-timeout-snapshot/snapshots ]]; then
    print_indented_command_output 'no NVMe timeout snapshots visible' ls -1dt /var/lib/nvme-timeout-snapshot/snapshots/*
  else
    echo '  snapshot directory unavailable'
  fi
}

print_storage_diagnostics() {
  local mount_source mount_fstype mount_options parent_device
  mount_source="$(findmnt -n -o SOURCE --target "$DATA_DIR" 2>/dev/null || true)"
  mount_fstype="$(findmnt -n -o FSTYPE --target "$DATA_DIR" 2>/dev/null || true)"
  mount_options="$(findmnt -n -o OPTIONS --target "$DATA_DIR" 2>/dev/null || true)"
  parent_device="$(resolve_storage_parent_device "$mount_source" 2>/dev/null || true)"

  echo "=== Storage diagnostics ==="
  echo "Data dir target:          $DATA_DIR"
  echo "Mount source:             ${mount_source:-unavailable}"
  echo "Mount filesystem:         ${mount_fstype:-unavailable}"
  echo "Mount options:            ${mount_options:-unavailable}"
  echo "Parent block device:      ${parent_device:-unavailable}"
  echo

  echo "Disk space usage:"
  print_indented_command_output 'df output unavailable' df -hP "$DATA_DIR"
  echo

  echo "Inode usage:"
  print_indented_command_output 'df inode output unavailable' df -iP "$DATA_DIR"
  echo

  if [[ -n "$parent_device" && -b "$parent_device" ]]; then
    echo "Block device summary:"
    print_indented_command_output 'lsblk output unavailable' lsblk -o NAME,TYPE,SIZE,FSTYPE,MODEL,MOUNTPOINTS "$parent_device"
    echo

    if command -v nvme >/dev/null 2>&1 && [[ "$parent_device" == /dev/nvme* ]]; then
      echo "NVMe SMART summary:"
      print_indented_command_output 'nvme smart-log unavailable or not permitted' nvme smart-log "$parent_device"
      echo
    fi

    if command -v smartctl >/dev/null 2>&1; then
      echo "SMART health summary:"
      print_indented_command_output 'smartctl health output unavailable or not permitted' smartctl -H "$parent_device"
      echo
    fi
  fi

  echo "Recent kernel storage hints:"
  print_recent_storage_kernel_hints
}

print_missing_bitcoin_config_status() {
  local matches="$1"
  echo
  echo "=== ODROID M1S Bitcoin recovery status ==="
  echo "Script version:           ${SCRIPT_VERSION:-unknown}"
  echo "Recovery mode:            unknown"
  echo "Bitcoin config dir:       unavailable"
  echo "State file:               $RECOVERY_STATE_FILE"
  echo
  if [[ -n "$matches" ]]; then
    echo "Config discovery issue:   multiple candidate Bitcoin config directories found"
    printf '%s\n' "$matches" | sed 's/^/  /'
  else
    echo "Config discovery issue:   no Umbrel Bitcoin config directory found under $DATA_DIR"
  fi
  echo
  echo "Current status: Bitcoin app config unavailable; storage and system diagnostics follow"
  echo
  print_system_diagnostics
  echo
  print_storage_diagnostics
  echo
  echo "If the Bitcoin app is installed, confirm it has created bitcoin.conf and umbrel-bitcoin.conf under $DATA_DIR."
}

# NOTE for maintainers: this is deliberately NOT read-only. Once a requested
# recovery has demonstrably started, it consumes the one-shot request from
# bitcoin.conf so Bitcoin does not reindex again on every later restart. This
# is currently the only consumer of a started request. Do not call it from a
# monitor, a loop, or another script expecting it to be side-effect free, and
# do not remove the consumption without adding a replacement consumer first.
run_recovery_status_check() {
  m1s_report_host_support
  require_root

  local config_matches config_count
  config_matches="$(locate_bitcoin_config_dir || true)"
  config_count="$(python3 -c 'import sys; print(len([line for line in sys.stdin.read().splitlines() if line.strip()]))' <<<"$config_matches")"
  if [[ "$config_count" -ne 1 ]]; then
    print_missing_bitcoin_config_status "$config_matches"
    return 0
  fi

  BITCOIN_CONFIG_DIR="$config_matches"
  BITCOIN_APP_DATA_DIR="$(dirname "$BITCOIN_CONFIG_DIR")"
  BITCOIN_CONF="$BITCOIN_CONFIG_DIR/bitcoin.conf"
  UMBREL_BITCOIN_CONF="$BITCOIN_CONFIG_DIR/umbrel-bitcoin.conf"
  DEBUG_LOG="$BITCOIN_CONFIG_DIR/debug.log"

  local settings_json config_reindex config_reindex_chainstate includeconf_present managed_present
  local state_file_present=0 request_epoch=0 active_request=0 had_prior_request=0 mode="unknown" log_mode="" runtime_mode=""
  local log_started=0 rpc_chainstates_ok=0 rpc_rebuild=0 rpc_progress="" rpc_blockchaininfo_ok=0 rpc_ibd=0 mode_known=0
  local blocks="" headers="" live_recovery_evidence=0 state status
  local chainstates_raw blockchaininfo_raw chainstates_summary blockchain_summary
  local reindex_log_json="" reindex_latest_file="" reindex_max_file="" reindex_progress_ratio="" reindex_loaded_blocks=""

  settings_json="$(read_effective_settings_json)"
  RECOVERY_STATE_JSON="$(read_recovery_state_json || true)"
  if [[ -n "$RECOVERY_STATE_JSON" ]]; then
    state_file_present=1
    had_prior_request=1
    request_epoch="$(recovery_state_field 'data.get("requested_at_epoch", 0)')"
    [[ -n "$request_epoch" ]] || request_epoch=0
    active_request="$(recovery_state_field '1 if data.get("active_request") else 0')"
    mode="$(recovery_state_field 'data.get("mode", "unknown")')"
  fi

  config_reindex="$(json_field "$settings_json" '1 if data["values"]["reindex"] == "1" else 0')"
  config_reindex_chainstate="$(json_field "$settings_json" '1 if data["values"]["reindex-chainstate"] == "1" else 0')"
  includeconf_present="$(json_field "$settings_json" 'data["includeconf_present"]')"
  managed_present="$(json_field "$settings_json" 'data["managed_present"]')"

  if [[ "$config_reindex" -eq 1 || "$config_reindex_chainstate" -eq 1 ]]; then
    active_request=1
    had_prior_request=1
  fi

  log_mode="$(infer_recovery_mode_from_log "$request_epoch" 2>/dev/null || true)"
  if [[ "$mode" != "unknown" ]]; then
    mode_known=1
  fi

  if [[ "$request_epoch" =~ ^[0-9]+$ ]] && (( request_epoch > 0 )) && recent_recovery_start_after_request "$request_epoch"; then
    log_started=1
  fi

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
    blocks="$(json_field "$blockchain_summary" 'data.get("blocks", "")')"
    headers="$(json_field "$blockchain_summary" 'data.get("headers", "")')"
  fi

  if [[ -z "$mode" || "$mode" == "unknown" ]]; then
    if [[ "$rpc_ibd" -eq 1 && -n "$blocks" && -n "$headers" && "$headers" != "0" ]]; then
      runtime_mode="full-download"
    fi
  fi

  mode="$(resolve_recovery_mode "$mode" "$config_reindex" "$config_reindex_chainstate" "$log_mode" "$runtime_mode")"
  if [[ "$mode" != "unknown" ]]; then
    mode_known=1
  fi

  if [[ "$mode_known" -eq 1 && ( "$rpc_rebuild" -eq 1 || "$rpc_ibd" -eq 1 ) ]]; then
    live_recovery_evidence=1
  fi

  if [[ "$active_request" -eq 1 && ( "$rpc_rebuild" -eq 1 || "$rpc_ibd" -eq 1 || "$log_started" -eq 1 ) ]]; then
    if [[ "$mode" == "chainstate-rebuild" || "$mode" == "reindex" ]]; then
      clear_managed_request_block >/dev/null
    fi
    mark_recovery_consumed "consumed-by-check"
    active_request=0
    RECOVERY_STATE_JSON="$(read_recovery_state_json || true)"
  fi

  if [[ "$had_prior_request" -eq 1 && "$active_request" -eq 0 && ( "$rpc_rebuild" -eq 1 || "$rpc_ibd" -eq 1 ) ]]; then
    live_recovery_evidence=1
  fi

  status="$(resolve_recovery_status "$active_request" "$live_recovery_evidence" "$log_started" "$had_prior_request" "$mode_known")"
  record_last_observed_state "$status"

  if [[ "$mode" == "reindex" || "$log_mode" == "reindex" || "$config_reindex" -eq 1 ]]; then
    reindex_log_json="$(summarize_reindex_log_progress "$request_epoch" 2>/dev/null || true)"
    if [[ -n "$reindex_log_json" ]]; then
      reindex_latest_file="$(json_field "$reindex_log_json" 'data.get("latest_file_name", "")')"
      reindex_max_file="$(json_field "$reindex_log_json" 'data.get("max_file_name", "")')"
      reindex_progress_ratio="$(json_field "$reindex_log_json" 'data.get("progress_ratio", "")')"
      reindex_loaded_blocks="$(json_field "$reindex_log_json" 'data.get("latest_loaded_blocks", "")')"
    fi
  fi

  echo
  echo "=== ODROID M1S Bitcoin recovery status ==="
  echo "Script version:           ${SCRIPT_VERSION:-unknown}"
  echo "Recovery mode:            $(mode_display_name "$mode")"
  echo "Bitcoin config dir:       $BITCOIN_CONFIG_DIR"
  echo "bitcoin.conf:             $BITCOIN_CONF"
  echo "umbrel-bitcoin.conf:      $UMBREL_BITCOIN_CONF"
  echo "debug.log:                $DEBUG_LOG"
  echo "State file:               $RECOVERY_STATE_FILE"
  echo "State file present:       $state_file_present"
  if [[ "$state_file_present" -eq 1 ]]; then
    echo "Requested at:             $(recovery_state_field 'data.get("requested_at_iso", "")')"
    echo "Active request:           $(recovery_state_field '1 if data.get("active_request") else 0')"
    echo "Last observed state:      $(recovery_state_field 'data.get("last_observed_state", "")')"
  fi
  echo "Include banner present:   $includeconf_present"
  echo "Config reindex present:   $config_reindex"
  echo "Config chainstate present:$config_reindex_chainstate"
  echo "Managed request block:    $managed_present"
  echo "Log mode hint:            ${log_mode:-none}"
  echo "Runtime mode hint:        ${runtime_mode:-none}"
  echo "Recent startup evidence:  $log_started"
  echo "RPC getchainstates:       $rpc_chainstates_ok"
  echo "RPC getblockchaininfo:    $rpc_blockchaininfo_ok"
  print_bitcoin_container_diagnostics
  if [[ -n "$blocks" || -n "$headers" ]]; then
    echo "Blocks / headers:         ${blocks:-unknown} / ${headers:-unknown}"
  fi
  if [[ -n "$rpc_progress" ]]; then
    echo "Approx progress:          $(format_progress_percent "$rpc_progress")"
  else
    echo "Approx progress:          unavailable"
  fi
  if [[ -n "$reindex_latest_file" || -n "$reindex_max_file" ]]; then
    echo "Reindex blk file:         ${reindex_latest_file:-unknown} / ${reindex_max_file:-unknown}"
  fi
  if [[ -n "$reindex_progress_ratio" ]]; then
    echo "Reindex file progress:    $(format_progress_percent "$reindex_progress_ratio")"
  fi
  if [[ -n "$reindex_loaded_blocks" ]]; then
    echo "Last file load blocks:    $reindex_loaded_blocks"
  fi
  echo
  print_human_status "$status" "$mode"
  echo
  echo "Recent Bitcoin error hints:"
  print_recent_bitcoin_error_hints
  echo
  print_system_diagnostics
  echo
  print_storage_diagnostics
  echo

  case "$status" in
    recovery-in-progress)
      echo "Use this same command again later to watch the live progress estimate."
      ;;
    recovery-started-progress-unavailable)
      echo "The node appears to have started the requested recovery, but live RPC progress is not reachable yet."
      echo "Retry this command after the Bitcoin app settles a bit more."
      ;;
    request-recorded-restart-not-confirmed)
      echo "The recovery request exists, but this script cannot prove that the Bitcoin app has consumed it yet."
      echo "If you just ran a start command, wait a bit and run this check again."
      ;;
    recovery-not-currently-detected)
      echo "A previous recovery request exists in the local state file, but no active recovery is visible right now."
      echo "If the Bitcoin app is healthy, the recovery may already be finished or no longer active."
      ;;
    recovery-inferred-from-runtime)
      echo "The node is showing runtime evidence that matches the inferred recovery mode above."
      echo "This usually means the recovery was started outside the new tracked scripts, but is still in progress."
      ;;
    no-recovery-detected)
      echo "No tracked Bitcoin recovery mode is visible right now."
      ;;
  esac
}
