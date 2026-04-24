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

SCRIPT_VERSION="0.4.2"
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

detect_lan_interface() {
  local iface=""
  iface="$(ip route show default 2>/dev/null | awk '/default/ {print $5; exit}' || true)"
  if [[ -n "$iface" && "$iface" != lo && "$iface" != docker* && "$iface" != br-* && "$iface" != veth* && "$iface" != tailscale* && "$iface" != virbr* && "$iface" != zt* ]]; then
    printf '%s\n' "$iface"
    return 0
  fi
  iface="$(ip -o link show 2>/dev/null | awk -F': ' '$2 !~ /^(lo|docker.*|br-.*|veth.*|tailscale.*|virbr.*|zt.*)$/ {print $2; exit}' || true)"
  printf '%s\n' "$iface"
}

ensure_nvme_diagnostic_tools() {
  local missing=()
  command -v lspci >/dev/null 2>&1 || missing+=(pciutils)
  command -v nvme >/dev/null 2>&1 || missing+=(nvme-cli)
  command -v smartctl >/dev/null 2>&1 || missing+=(smartmontools)
  [[ "${#missing[@]}" -gt 0 ]] || return 0

  if [[ "$DRY_RUN" -eq 1 ]]; then
    echo "[DRY-RUN] apt-get install -y ${missing[*]}"
    return 0
  fi

  DEBIAN_FRONTEND=noninteractive apt-get install -y "${missing[@]}" >/dev/null 2>&1 || warn "Failed to install NVMe diagnostic tools (${missing[*]}); snapshotter will capture available commands only"
}

install_nvme_timeout_snapshotter() {
  local snapshot_script="/usr/local/sbin/nvme-timeout-snapshot.sh"
  local snapshot_service="/etc/systemd/system/nvme-timeout-snapshot.service"
  local snapshot_timer="/etc/systemd/system/nvme-timeout-snapshot.timer"
  if [[ "$DRY_RUN" -eq 1 ]]; then
    echo "[DRY-RUN] create $snapshot_script"
    echo "[DRY-RUN] create $snapshot_service"
    echo "[DRY-RUN] create $snapshot_timer"
    echo "[DRY-RUN] systemctl enable --now nvme-timeout-snapshot.timer"
    return 0
  fi

  cat > "$snapshot_script" <<'EOF'
#!/bin/bash
set -euo pipefail
STATE_DIR="/var/lib/nvme-timeout-snapshot"
SNAPSHOT_DIR="$STATE_DIR/snapshots"
BOOT_ID="$(cat /proc/sys/kernel/random/boot_id 2>/dev/null || echo unknown-boot)"
BOOT_FLAG="$STATE_DIR/captured-$BOOT_ID"
mkdir -p "$SNAPSHOT_DIR"

if [ -e "$BOOT_FLAG" ]; then
  exit 0
fi

if ! journalctl -k -b --no-pager 2>/dev/null | grep -Eiq 'nvme.*timeout|EXT4-fs error|I/O error|blk_update_request|Buffer I/O|aborted journal|read-only filesystem'; then
  exit 0
fi

ts="$(date +%Y%m%d-%H%M%S)"
snapshot="$SNAPSHOT_DIR/$ts-nvme-timeout"
mkdir -p "$snapshot"
{
  echo "timestamp=$(date -Is)"
  echo "boot_id=$BOOT_ID"
  echo "reason=kernel-storage-warning"
} > "$snapshot/meta.txt"
cat /proc/cmdline > "$snapshot/cmdline.txt" 2>/dev/null || true
findmnt /mnt/fullnode > "$snapshot/findmnt-fullnode.txt" 2>&1 || true
lsblk -o NAME,SIZE,TYPE,MODEL,FSTYPE,MOUNTPOINT,UUID > "$snapshot/lsblk.txt" 2>&1 || true
journalctl -k -b --no-pager | grep -Ei 'nvme|EXT4-fs error|timeout|I/O error|blk_update_request|Buffer I/O|aborted journal|read-only filesystem' > "$snapshot/kernel-storage.log" 2>&1 || true
lspci -vv > "$snapshot/lspci-vv.txt" 2>&1 || true
if command -v nvme >/dev/null 2>&1; then
  nvme list > "$snapshot/nvme-list.txt" 2>&1 || true
  nvme id-ctrl /dev/nvme0 > "$snapshot/nvme-id-ctrl.txt" 2>&1 || true
  nvme smart-log /dev/nvme0 > "$snapshot/nvme-smart-log.txt" 2>&1 || true
fi
if command -v smartctl >/dev/null 2>&1; then
  smartctl -a /dev/nvme0 > "$snapshot/smartctl.txt" 2>&1 || true
fi
date -Is > "$BOOT_FLAG"
EOF
  chmod 0755 "$snapshot_script"

  cat > "$snapshot_service" <<EOF
[Unit]
Description=Capture NVMe timeout diagnostics when kernel storage warnings appear
After=local-fs.target

[Service]
Type=oneshot
ExecStart=$snapshot_script
EOF

  cat > "$snapshot_timer" <<'EOF'
[Unit]
Description=Periodic passive NVMe timeout diagnostic capture

[Timer]
OnBootSec=2min
OnUnitActiveSec=5min
AccuracySec=30s
Unit=nvme-timeout-snapshot.service

[Install]
WantedBy=timers.target
EOF

  systemctl daemon-reload
  systemctl enable --now nvme-timeout-snapshot.timer >/dev/null 2>&1 || warn "Failed to enable NVMe timeout diagnostic snapshot timer"
  info "Installed passive NVMe timeout diagnostic snapshot timer"
}

patch_to_0_4_0() {
  local conf="/etc/avahi/avahi-daemon.conf"
  local alias_script="/usr/local/bin/avahi-publish-umbrel"
  local alias_service="/etc/systemd/system/avahi-alias-umbrel.service"
  local extlinux_conf="/boot/extlinux/extlinux.conf"
  local lan_interface
  local umbrel_hostname="umbrel"
  local current_hostname

  current_hostname="$(hostnamectl --static 2>/dev/null || hostname)"
  if [[ "$current_hostname" != "$umbrel_hostname" ]]; then
    if [[ "$DRY_RUN" -eq 1 ]]; then
      echo "[DRY-RUN] hostnamectl set-hostname $umbrel_hostname (was: $current_hostname)"
      echo "[DRY-RUN] update /etc/hosts 127.0.1.1 line to $umbrel_hostname"
    else
      hostnamectl set-hostname "$umbrel_hostname" || warn "[0.4.0] hostnamectl set-hostname failed (continuing)"
      if grep -qE '^127\.0\.1\.1[[:space:]]' /etc/hosts; then
        sed -i "s/^127\.0\.1\.1[[:space:]].*/127.0.1.1\t$umbrel_hostname/" /etc/hosts
      else
        printf '127.0.1.1\t%s\n' "$umbrel_hostname" >> /etc/hosts
      fi
      info "[0.4.0] Hostname changed to $umbrel_hostname (was: $current_hostname) for native umbrel.local mDNS"
    fi
  else
    info "[0.4.0] Hostname already $umbrel_hostname; skipping rename"
  fi

  lan_interface="$(detect_lan_interface)"
  [[ -n "$lan_interface" ]] || lan_interface="eth0"
  info "[0.4.0] Hardening avahi-daemon and umbrel.local alias on $lan_interface"

  if [[ "$DRY_RUN" -eq 1 ]]; then
    echo "[DRY-RUN] set allow-interfaces=$lan_interface in $conf"
    echo "[DRY-RUN] rewrite $alias_script"
    echo "[DRY-RUN] rewrite $alias_service"
    echo "[DRY-RUN] systemctl enable --now avahi-daemon avahi-alias-umbrel.service"
    return 0
  fi

  if [[ -f "$conf" ]]; then
    cp "$conf" "$conf.bak.$(date +%s)"
    python3 - "$conf" "$lan_interface" <<'PY'
import re
import sys
from pathlib import Path
path = Path(sys.argv[1])
iface = sys.argv[2]
text = path.read_text()
if re.search(r'^allow-interfaces=', text, flags=re.M):
    text = re.sub(r'^allow-interfaces=.*$', f'allow-interfaces={iface}', text, flags=re.M)
elif re.search(r'^#allow-interfaces=', text, flags=re.M):
    text = re.sub(r'^#allow-interfaces=.*$', f'allow-interfaces={iface}', text, flags=re.M)
else:
    text = re.sub(r'(\[server\]\n)', rf'\1allow-interfaces={iface}\n', text, count=1)
path.write_text(text)
PY
  fi

  cat > "$alias_script" <<'ALIASSCRIPT'
#!/usr/bin/env bash
set -eu
while true; do
  IFACE="$(ip route show default 2>/dev/null | awk '/default/ {print $5; exit}' || true)"
  if [[ -z "$IFACE" ]]; then
    sleep 5
    continue
  fi
  IP="$(ip -4 -o addr show dev "$IFACE" scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -n1)"
  if [[ -n "$IP" ]]; then
    exec avahi-publish-address -R umbrel.local "$IP"
  fi
  sleep 5
done
ALIASSCRIPT
  chmod 0755 "$alias_script"

  cat > "$alias_service" <<'SERVICEUNIT'
[Unit]
Description=Publish umbrel.local mDNS alias
After=avahi-daemon.service network-online.target
Requires=avahi-daemon.service
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/local/bin/avahi-publish-umbrel
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
SERVICEUNIT

  systemctl daemon-reload
  systemctl enable --now avahi-daemon >/dev/null 2>&1 || warn "[0.4.0] Failed to enable/start avahi-daemon"
  systemctl restart avahi-daemon || warn "[0.4.0] Failed to restart avahi-daemon"
  systemctl enable --now avahi-alias-umbrel.service >/dev/null 2>&1 || warn "[0.4.0] Failed to enable/start avahi-alias-umbrel.service"

  # On ODROID M1S the u-boot loader reads /boot/extlinux/extlinux.conf directly
  # for the kernel cmdline, so NVMe/PCIe hardening parameters in
  # /etc/default/flash-kernel are not applied on the next boot. Patch the
  # extlinux append line so the hardening actually takes effect.
  if [[ -f "$extlinux_conf" ]]; then
    cp "$extlinux_conf" "$extlinux_conf.bak.$(date +%s)"
    python3 - "$extlinux_conf" <<'PY'
import sys
from pathlib import Path
path = Path(sys.argv[1])
needles = [
    'nvme_core.default_ps_max_latency_us=0',
    'pcie_aspm=off',
    'pcie_port_pm=off',
]
lines = path.read_text().splitlines()
changed = False
for i, line in enumerate(lines):
    stripped = line.lstrip()
    if not stripped.startswith('append '):
        continue
    indent = line[:len(line) - len(stripped)]
    parts = stripped.split()
    for needle in needles:
        if needle not in parts:
            parts.append(needle)
            changed = True
    lines[i] = indent + ' '.join(parts)
if changed:
    path.write_text('\n'.join(lines) + '\n')
PY
    info "[0.4.0] Patched $extlinux_conf with NVMe/PCIe parameters"
  else
    warn "[0.4.0] $extlinux_conf not found; skipping extlinux cmdline patch"
  fi

  # Disable unattended-upgrades automatic reboot so the node never restarts on
  # its own after a security upgrade pulls in a new kernel.
  local apt_noreboot="/etc/apt/apt.conf.d/52m1s-no-auto-reboot"
  if [[ ! -f "$apt_noreboot" ]] || ! grep -q 'Automatic-Reboot "false"' "$apt_noreboot"; then
    cat > "$apt_noreboot" <<'APT_CONF'
Unattended-Upgrade::Automatic-Reboot "false";
Unattended-Upgrade::Automatic-Reboot-WithUsers "false";
APT_CONF
    chmod 0644 "$apt_noreboot"
    info "[0.4.0] Wrote $apt_noreboot (automatic reboot disabled)"
  else
    info "[0.4.0] $apt_noreboot already disables automatic reboot"
  fi

  # Ensure Docker log rotation is configured so daemon json-file logs do not
  # grow unbounded on long-running nodes.
  local docker_json="/etc/docker/daemon.json"
  local docker_needs_rewrite=1
  if [[ -f "$docker_json" ]] && grep -q 'max-size' "$docker_json" && grep -q 'max-file' "$docker_json"; then
    docker_needs_rewrite=0
  fi
  if [[ "$docker_needs_rewrite" -eq 1 ]]; then
    mkdir -p /etc/docker
    if [[ -f "$docker_json" ]]; then
      cp "$docker_json" "$docker_json.bak.$(date +%s)"
    fi
    cat > "$docker_json" <<'DOCKER_JSON'
{
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "10m",
    "max-file": "5"
  }
}
DOCKER_JSON
    chmod 0644 "$docker_json"
    if systemctl is-active docker >/dev/null 2>&1; then
      systemctl restart docker || warn "[0.4.0] Failed to restart docker after $docker_json update"
    fi
    info "[0.4.0] Wrote $docker_json with log rotation"
  else
    info "[0.4.0] $docker_json already has log rotation"
  fi

  # Create a 4G swapfile on the Umbrel data mount so Bitcoin IBD and similar
  # memory-heavy workloads do not OOM the Umbrel containers on 8GB boards.
  local swapfile="/mnt/fullnode/swapfile"
  local swap_size_mb=4096
  if [[ -d /mnt/fullnode ]]; then
    if swapon --noheadings --raw --output=NAME 2>/dev/null | grep -qx "$swapfile"; then
      info "[0.4.0] Swapfile $swapfile already active; skipping"
    else
      if [[ ! -f "$swapfile" ]]; then
        if command -v fallocate >/dev/null 2>&1; then
          fallocate -l "${swap_size_mb}M" "$swapfile"
        else
          dd if=/dev/zero of="$swapfile" bs=1M count="$swap_size_mb" status=none
        fi
      fi
      chmod 600 "$swapfile"
      mkswap "$swapfile" >/dev/null || warn "[0.4.0] mkswap $swapfile failed (continuing)"
      swapon "$swapfile" || warn "[0.4.0] swapon $swapfile failed (continuing)"
      if ! grep -qE "^$swapfile[[:space:]]" /etc/fstab; then
        printf '%s\tnone\tswap\tsw,nofail\t0\t0\n' "$swapfile" >> /etc/fstab
        info "[0.4.0] Added $swapfile to /etc/fstab"
      fi
    fi
  else
    warn "[0.4.0] /mnt/fullnode not present; skipping swapfile creation"
  fi
}

patch_to_0_4_1() {
  info "[0.4.1] Installing passive NVMe timeout diagnostic snapshotter"
  install_nvme_timeout_snapshotter
}

patch_to_0_4_2() {
  info "[0.4.2] Ensuring NVMe diagnostic tools are available"
  ensure_nvme_diagnostic_tools
  install_nvme_timeout_snapshotter
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
if version_lt "$CURRENT_VERSION" "0.4.0"; then
  PLANNED_PATCHES+=("0.4.0")
fi
if version_lt "$CURRENT_VERSION" "0.4.1"; then
  PLANNED_PATCHES+=("0.4.1")
fi
if version_lt "$CURRENT_VERSION" "0.4.2"; then
  PLANNED_PATCHES+=("0.4.2")
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
    0.4.0)
      patch_to_0_4_0
      ;;
    0.4.1)
      patch_to_0_4_1
      ;;
    0.4.2)
      patch_to_0_4_2
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
