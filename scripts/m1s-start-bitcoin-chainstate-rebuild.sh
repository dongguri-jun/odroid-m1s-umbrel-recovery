#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_VERSION="0.5.5"
DATA_DIR="/mnt/fullnode"
STATE_DIR="/etc/umbrel-recovery"
REQUEST_STATE_FILE="$STATE_DIR/bitcoin-chainstate-rebuild.json"
DRY_RUN=0
MANAGED_BEGIN="# m1s-bitcoin-chainstate-rebuild: begin"
MANAGED_END="# m1s-bitcoin-chainstate-rebuild: end"

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

usage() {
  cat <<'EOF'
ODROID M1S Umbrel — start Bitcoin chainstate rebuild

Usage:
  sudo bash scripts/m1s-start-bitcoin-chainstate-rebuild.sh [options]

Options:
  --dry-run      Show actions without changing anything.
  --version      Print script version and exit.
  -h, --help     Show this help.

What this script does:
  - Finds Umbrel's live Bitcoin config directory on the ODROID host.
  - Adds a temporary reindex-chainstate=1 request to the custom bitcoin.conf section.
  - Restarts the live Bitcoin app container automatically.
  - Records a local state file so the paired check command can confirm progress.

After this command finishes, monitor the result with:
  sudo bash scripts/m1s-check-bitcoin-chainstate-rebuild.sh

Host-shell note:
  - Run this from the ODROID host shell.
  - In Umbrel web UI Terminal, first enter host shell with:
      sudo nsenter -t 1 -m -u -i -n -p -- bash
EOF
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --dry-run)
        DRY_RUN=1
        ;;
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
    shift
  done
}

require_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    err "Run this script with sudo or as root."
    exit 1
  fi
}

ensure_state_dir() {
  run_cmd mkdir -p "$STATE_DIR"
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

value_is_truthy() {
  local raw="${1,,}"
  [[ -n "$raw" && "$raw" != "0" && "$raw" != "false" && "$raw" != "no" ]]
}

require_safe_effective_config() {
  local settings_json="$1"
  local prune_value reindex_value
  prune_value="$(json_field "$settings_json" 'data["values"]["prune"]')"
  reindex_value="$(json_field "$settings_json" 'data["values"]["reindex"]')"

  if value_is_truthy "$prune_value"; then
    err "Effective Bitcoin config still enables prune=$prune_value"
    err "Bitcoin Core rejects reindex-chainstate in prune mode. Use full reindex instead."
    exit 1
  fi

  if value_is_truthy "$reindex_value"; then
    err "Effective Bitcoin config already has reindex=$reindex_value"
    err "Refusing to combine reindex and reindex-chainstate requests."
    exit 1
  fi
}

backup_file() {
  local file="$1"
  local backup_path
  backup_path="$file.backup.$(date +%s)"
  run_cmd cp -a "$file" "$backup_path"
  info "Backup written: $backup_path"
}

write_request_block() {
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
    if stripped.startswith('reindex-chainstate=') and stripped.split('=', 1)[1].split('#', 1)[0].strip() == '1':
        found_request = True
    output.append(line)

status = 'added'
if found_request:
    status = 'already-present'
else:
    while output and output[-1] == '':
        output.pop()
    if output:
        output.append('')
    output.extend([
        managed_begin,
        'reindex-chainstate=1',
        managed_end,
    ])

path.write_text('\n'.join(output) + '\n', encoding='utf-8')
print(status)
PY
}

write_request_state() {
  if [[ "$DRY_RUN" -eq 1 ]]; then
    echo "[DRY-RUN] write $REQUEST_STATE_FILE"
    return 0
  fi

  python3 - "$REQUEST_STATE_FILE" "$BITCOIN_CONFIG_DIR" "$BITCOIN_CONF" <<'PY'
from pathlib import Path
import datetime as dt
import json
import time
import sys

path = Path(sys.argv[1])
config_dir = sys.argv[2]
bitcoin_conf = sys.argv[3]
path.parent.mkdir(parents=True, exist_ok=True)
now = dt.datetime.now(dt.timezone.utc)
payload = {
    'active_request': True,
    'requested_at_epoch': int(time.time()),
    'requested_at_iso': now.isoformat(),
    'config_dir': config_dir,
    'bitcoin_conf': bitcoin_conf,
    'request': 'reindex-chainstate=1',
    'restart_attempted_at_epoch': None,
    'restart_attempted_at_iso': None,
    'restart_succeeded': False,
    'request_consumed_at_epoch': None,
    'request_consumed_at_iso': None,
    'last_observed_state': 'requested',
    'source': 'm1s-start-bitcoin-chainstate-rebuild.sh',
}
path.write_text(json.dumps(payload, indent=2, sort_keys=True) + '\n', encoding='utf-8')
PY
}

update_request_state_for_restart() {
  local restart_succeeded="$1"
  if [[ "$DRY_RUN" -eq 1 ]]; then
    echo "[DRY-RUN] update $REQUEST_STATE_FILE restart_succeeded=$restart_succeeded"
    return 0
  fi

  python3 - "$REQUEST_STATE_FILE" "$restart_succeeded" <<'PY'
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

locate_bitcoin_container() {
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

print_status() {
  local settings_json="$1"
  echo
  echo "=== ODROID M1S Bitcoin chainstate rebuild start ==="
  echo "Script version:        $SCRIPT_VERSION"
  echo "Bitcoin config dir:    $BITCOIN_CONFIG_DIR"
  echo "bitcoin.conf:          $BITCOIN_CONF"
  echo "umbrel-bitcoin.conf:   $UMBREL_BITCOIN_CONF"
  echo "debug.log:             $DEBUG_LOG"
  echo "Request state file:    $REQUEST_STATE_FILE"
  echo "Dry run:               $DRY_RUN"
  echo
  echo "Effective config values:"
  echo "  prune:               $(json_field "$settings_json" 'data["values"]["prune"]')"
  echo "  reindex:             $(json_field "$settings_json" 'data["values"]["reindex"]')"
  echo "  reindex-chainstate:  $(json_field "$settings_json" 'data["values"]["reindex-chainstate"]')"
  echo
}

main() {
  parse_args "$@"
  require_root
  require_single_bitcoin_config_dir

  if [[ ! -f "$BITCOIN_CONF" || ! -f "$UMBREL_BITCOIN_CONF" ]]; then
    err "Expected both bitcoin.conf and umbrel-bitcoin.conf in $BITCOIN_CONFIG_DIR"
    exit 1
  fi

  local settings_json
  settings_json="$(read_effective_settings_json)"
  print_status "$settings_json"
  require_safe_effective_config "$settings_json"

  ensure_state_dir
  backup_file "$BITCOIN_CONF"

  local write_status
  write_status="$(write_request_block)"
  write_request_state

  local locate_output
  locate_output="$(locate_bitcoin_container || true)"
  if [[ -z "$locate_output" ]]; then
    update_request_state_for_restart 0
    err "Could not locate the live Bitcoin app container from host Docker mounts."
    err "The request was written, but the app restart could not be automated."
    err "If you are in Umbrel web UI Terminal, confirm you already entered host shell with: sudo nsenter -t 1 -m -u -i -n -p -- bash"
    exit 1
  fi

  local container_name container_data_dir
  container_name="$(printf '%s\n' "$locate_output" | sed -n '1p')"
  container_data_dir="$(printf '%s\n' "$locate_output" | sed -n '2p')"

  echo "Write result: $write_status"
  echo "Bitcoin container: $container_name"
  echo "Container data dir: $container_data_dir"

  if [[ "$DRY_RUN" -eq 1 ]]; then
    echo "[DRY-RUN] docker restart $container_name"
    update_request_state_for_restart 1
    echo
    echo "[DRY-RUN] Start flow prepared."
    echo "Next step: run sudo bash scripts/m1s-check-bitcoin-chainstate-rebuild.sh"
    exit 0
  fi

  info "Restarting Bitcoin app container: $container_name"
  docker restart "$container_name" >/dev/null
  if ! wait_for_container_running "$container_name"; then
    update_request_state_for_restart 0
    err "Bitcoin container did not return to running state after restart."
    err "Run the check command for more detail: sudo bash scripts/m1s-check-bitcoin-chainstate-rebuild.sh"
    exit 1
  fi

  update_request_state_for_restart 1

  echo
  echo "Chainstate rebuild request recorded and Bitcoin app restart sent."
  echo "Now confirm progress with:"
  echo "  sudo bash scripts/m1s-check-bitcoin-chainstate-rebuild.sh"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
