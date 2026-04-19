#!/usr/bin/env bash
set -Eeuo pipefail

# ODROID M1S Umbrel recovery — in-place updater.
#
# This script upgrades an existing installation made by
# m1s-clean-install-umbrel.sh without touching user data.
# It is safe to run repeatedly (idempotent).
#
# Usage:
#   sudo bash m1s-update-umbrel.sh [options]
#
# Options:
#   --check        Print current/target versions and planned patches, then exit.
#   --dry-run      Show actions without changing anything.
#   --version      Print script version and exit.
#   -h, --help     Show this help.

SCRIPT_VERSION="0.3.0"
INSTALL_STATE_DIR="/etc/umbrel-recovery"
INSTALL_STATE_FILE="$INSTALL_STATE_DIR/installed.json"

DRY_RUN=0
CHECK_ONLY=0

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
ODROID M1S Umbrel recovery — in-place updater

Usage:
  sudo bash m1s-update-umbrel.sh [options]

Options:
  --check        Print current/target versions and planned patches, then exit.
  --dry-run      Show actions without changing anything.
  --version      Print script version and exit.
  -h, --help     Show this help.

Notes:
  - Run this on a host that was already set up with m1s-clean-install-umbrel.sh.
  - The updater never formats disks, never deletes user data, and never
    recreates the Umbrel container. It only applies targeted patches such as
    configuration fixes.
  - Safe to run repeatedly (idempotent).
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --check)
      CHECK_ONLY=1
      ;;
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

if [[ "${EUID}" -ne 0 ]]; then
  err "Run this script with sudo or as root."
  exit 1
fi

# ---------------------------------------------------------------------------
# Version ordering helpers
# ---------------------------------------------------------------------------

# Return 0 if $1 is strictly less than $2, else 1.
version_lt() {
  [[ "$1" == "$2" ]] && return 1
  local lower
  lower="$(printf '%s\n%s\n' "$1" "$2" | sort -V | head -n1)"
  [[ "$lower" == "$1" ]]
}

# ---------------------------------------------------------------------------
# Detect currently installed version
# ---------------------------------------------------------------------------

read_installed_version_from_state() {
  [[ -f "$INSTALL_STATE_FILE" ]] || return 1
  python3 - "$INSTALL_STATE_FILE" <<'PY' 2>/dev/null
import json, sys
try:
    with open(sys.argv[1]) as f:
        data = json.load(f)
    v = data.get("version")
    if isinstance(v, str) and v:
        print(v)
except Exception:
    sys.exit(1)
PY
}

# Heuristically guess the installed version when installed.json is missing.
# This lets users who installed before 0.3.0 still update without reinstalling.
heuristic_installed_version() {
  # 0.2.0 shipped the fullnode-mount-guard service.
  if [[ -f /etc/systemd/system/fullnode-mount-guard.service ]] \
     || [[ -f /usr/local/sbin/fullnode-mount-guard.sh ]]; then
    printf '0.2.0\n'
    return 0
  fi
  # 0.1.0 was the initial public release with no guard service.
  if command -v docker >/dev/null 2>&1 && docker inspect umbrel >/dev/null 2>&1; then
    printf '0.1.0\n'
    return 0
  fi
  # No Umbrel found at all.
  printf 'unknown\n'
}

detect_installed_version() {
  local v
  if v="$(read_installed_version_from_state)" && [[ -n "$v" ]]; then
    printf '%s\n' "$v"
    return 0
  fi
  heuristic_installed_version
}

# ---------------------------------------------------------------------------
# Patch: 0.3.0 — restrict avahi-daemon to eth0 so Docker veth interfaces do
# not pollute mDNS responses. Also make sure avahi is installed.
# ---------------------------------------------------------------------------

patch_to_0_3_0() {
  info "[0.3.0] Restricting avahi-daemon to eth0"

  # Ensure avahi + libnss-mdns are present. If the 0.2.0 installer already
  # added them this is a no-op.
  if ! dpkg -s avahi-daemon >/dev/null 2>&1; then
    info "[0.3.0] Installing avahi-daemon avahi-utils libnss-mdns"
    if [[ "$DRY_RUN" -eq 1 ]]; then
      echo "[DRY-RUN] apt-get install -y avahi-daemon avahi-utils libnss-mdns"
    else
      DEBIAN_FRONTEND=noninteractive apt-get install -y \
        avahi-daemon avahi-utils libnss-mdns >/dev/null 2>&1 || \
        warn "Failed to install avahi packages (continuing)"
    fi
  fi

  local conf="/etc/avahi/avahi-daemon.conf"
  if [[ ! -f "$conf" ]]; then
    warn "[0.3.0] $conf not found; skipping avahi hardening"
    return 0
  fi

  if grep -qE '^allow-interfaces=' "$conf"; then
    info "[0.3.0] avahi allow-interfaces already set; nothing to do"
    return 0
  fi

  if [[ "$DRY_RUN" -eq 1 ]]; then
    echo "[DRY-RUN] backup $conf"
    echo "[DRY-RUN] set allow-interfaces=eth0 in $conf"
    echo "[DRY-RUN] systemctl restart avahi-daemon"
    return 0
  fi

  cp "$conf" "$conf.bak.$(date +%s)"
  sed -i 's/^#allow-interfaces=.*/allow-interfaces=eth0/' "$conf"
  if ! grep -qE '^allow-interfaces=' "$conf"; then
    # Template did not have the commented key; insert under [server].
    python3 - "$conf" <<'PY'
import sys, re
from pathlib import Path
p = Path(sys.argv[1])
text = p.read_text()
if re.search(r'^allow-interfaces=', text, flags=re.M):
    sys.exit(0)
text = re.sub(r'(\[server\]\n)', r'\1allow-interfaces=eth0\n', text, count=1)
p.write_text(text)
PY
  fi
  systemctl restart avahi-daemon || warn "Failed to restart avahi-daemon (continuing)"
  info "[0.3.0] avahi-daemon is now bound to eth0 only"
}

# ---------------------------------------------------------------------------
# Record the new version in the install state file.
# ---------------------------------------------------------------------------

write_install_state() {
  local new_version="$1"
  local previous_version="$2"
  if [[ "$DRY_RUN" -eq 1 ]]; then
    echo "[DRY-RUN] update $INSTALL_STATE_FILE (version=$new_version)"
    return 0
  fi
  mkdir -p "$INSTALL_STATE_DIR"
  local ts
  ts="$(date -Is)"
  python3 - "$INSTALL_STATE_FILE" "$new_version" "$ts" "$previous_version" <<'PY'
import json, os, sys, tempfile

path, new_version, ts, previous = sys.argv[1:5]

base = {}
if os.path.exists(path):
    try:
        with open(path) as f:
            base = json.load(f)
    except Exception:
        base = {}

base["version"] = new_version
base["updated_at"] = ts
base["updated_by"] = "m1s-update-umbrel.sh"
if previous and previous != new_version:
    base.setdefault("previous_version", previous)

d = os.path.dirname(path)
fd, tmp = tempfile.mkstemp(dir=d, prefix="installed.tmp.")
with os.fdopen(fd, "w") as f:
    json.dump(base, f, indent=2)
    f.write("\n")
os.chmod(tmp, 0o644)
os.rename(tmp, path)
PY
}

# ---------------------------------------------------------------------------
# Main flow
# ---------------------------------------------------------------------------

TARGET_VERSION="$SCRIPT_VERSION"
CURRENT_VERSION="$(detect_installed_version)"

echo
echo "=== ODROID M1S Umbrel recovery updater ==="
echo "Script version:     $SCRIPT_VERSION"
echo "Installed version:  $CURRENT_VERSION"
echo "Target version:     $TARGET_VERSION"
echo "Install state file: $INSTALL_STATE_FILE"
if [[ -f "$INSTALL_STATE_FILE" ]]; then
  echo "Install state:      present"
else
  echo "Install state:      missing (heuristic detection)"
fi
echo "Dry run:            $DRY_RUN"
echo

if [[ "$CURRENT_VERSION" == "unknown" ]]; then
  err "Could not detect a previous Umbrel installation on this host."
  err "If this is a fresh machine, run m1s-clean-install-umbrel.sh instead."
  exit 1
fi

# Build the ordered list of patches that would apply from CURRENT to TARGET.
PLANNED_PATCHES=()
if version_lt "$CURRENT_VERSION" "0.3.0"; then
  PLANNED_PATCHES+=("0.3.0")
fi

if [[ "${#PLANNED_PATCHES[@]}" -eq 0 ]]; then
  echo "No patches needed. Host is already at $CURRENT_VERSION (>= $TARGET_VERSION)."
  exit 0
fi

echo "Planned patches:"
for p in "${PLANNED_PATCHES[@]}"; do
  echo "  - $CURRENT_VERSION -> $p"
done
echo

if [[ "$CHECK_ONLY" -eq 1 ]]; then
  echo "--check specified; not applying anything."
  exit 0
fi

for patch in "${PLANNED_PATCHES[@]}"; do
  case "$patch" in
    0.3.0)
      patch_to_0_3_0
      ;;
    *)
      warn "No handler for patch target '$patch'; skipping"
      ;;
  esac
done

write_install_state "$TARGET_VERSION" "$CURRENT_VERSION"

echo
echo "==========================================="
echo "  Update complete."
echo "==========================================="
echo "Host is now at version: $TARGET_VERSION"
echo
if [[ "$DRY_RUN" -eq 1 ]]; then
  echo "[DRY-RUN] No changes were actually made."
fi
