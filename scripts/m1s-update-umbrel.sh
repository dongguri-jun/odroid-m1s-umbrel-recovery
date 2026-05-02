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

SCRIPT_VERSION="0.4.14"
INSTALL_STATE_DIR="/etc/umbrel-recovery"
INSTALL_STATE_FILE="$INSTALL_STATE_DIR/installed.json"
DATA_DIR="/mnt/fullnode"
UMBREL_IMAGE="dockurr/umbrel:1.5.0@sha256:4631e3da4ede19f0d6fc21f304d9994db5adba4ed3df786f9d249ee26733381a"
SAFE_SHUTDOWN_SERVICE="/etc/systemd/system/m1s-umbrel-autostart.service"

DRY_RUN=0
CHECK_ONLY=0

MIGRATIONS=(
  "0.1.0_to_0.2.0"
  "0.2.0_to_0.3.0"
  "0.3.0_to_0.4.0"
  "0.4.0_to_0.4.1"
  "0.4.1_to_0.4.2"
  "0.4.2_to_0.4.3"
  "0.4.3_to_0.4.4"
  "0.4.4_to_0.4.5"
  "0.4.5_to_0.4.6"
  "0.4.6_to_0.4.7"
  "0.4.7_to_0.4.8"
  "0.4.8_to_0.4.9"
  "0.4.9_to_0.4.10"
  "0.4.10_to_0.4.11"
  "0.4.11_to_0.4.12"
  "0.4.12_to_0.4.13"
  "0.4.13_to_0.4.14"
)

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

wait_for_apt_locks() {
  if [[ "$DRY_RUN" -eq 1 ]]; then
    echo "[DRY-RUN] wait for apt/dpkg locks to be released"
    return 0
  fi

  local locks=(/var/lib/dpkg/lock-frontend /var/lib/dpkg/lock /var/lib/apt/lists/lock)
  local max_wait=900
  local waited=0
  local printed_notice=0

  while (( waited < max_wait )); do
    local holder=""
    for lock in "${locks[@]}"; do
      [[ -e "$lock" ]] || continue
      local pids
      pids="$({ fuser "$lock" 2>/dev/null || true; } | tr -s ' ' | sed 's/^ //; s/ $//')"
      if [[ -n "$pids" ]]; then
        holder="$pids"
        break
      fi
    done
    if [[ -z "$holder" ]]; then
      return 0
    fi
    if [[ "$printed_notice" -eq 0 ]]; then
      warn "Another process is holding apt/dpkg locks (likely unattended-upgrades)."
      warn "Waiting up to 15 minutes for it to finish before continuing..."
      printed_notice=1
    fi
    sleep 5
    waited=$((waited + 5))
    if (( waited % 60 == 0 )); then
      info "Still waiting for apt/dpkg locks ($((waited / 60)) min elapsed, holder PID: $holder)"
    fi
  done

  err "apt/dpkg locks were still held after 15 minutes. Rerun this script after the update finishes."
  return 1
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
  - The updater never formats disks and never deletes user data. It may refresh
    the Umbrel system container only after validating that /data is backed by
    the existing /mnt/fullnode data mount.
  - Safe to run repeatedly (idempotent).
EOF
}

parse_args() {
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
}

require_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    err "Run this script with sudo or as root."
    exit 1
  fi
}

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
    for key in ("host_version", "version"):
        v = data.get(key)
        if isinstance(v, str) and v:
            print(v)
            sys.exit(0)
    steps = data.get("applied_steps")
    if isinstance(steps, list) and steps:
        last = steps[-1]
        if isinstance(last, str) and "_to_" in last:
            print(last.rsplit("_to_", 1)[1])
            sys.exit(0)
except Exception:
    sys.exit(1)
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

nvme_cmdline_patch_flash_kernel_defaults() {
  local flash_kernel_defaults="/etc/default/flash-kernel"
  if [[ "$DRY_RUN" -eq 1 ]]; then
    echo "[DRY-RUN] backup $flash_kernel_defaults"
    echo "[DRY-RUN] append nvme_core.default_ps_max_latency_us=0 pcie_aspm=off pcie_port_pm=off to LINUX_KERNEL_CMDLINE"
    echo "[DRY-RUN] flash-kernel"
  elif [[ -f "$flash_kernel_defaults" ]]; then
    run_cmd cp "$flash_kernel_defaults" "$flash_kernel_defaults.bak.$(date +%s)"
    FLASH_KERNEL_FILE="$flash_kernel_defaults" python3 - <<'PY'
from pathlib import Path
import os

path = Path(os.environ['FLASH_KERNEL_FILE'])
needles = [
    'nvme_core.default_ps_max_latency_us=0',
    'pcie_aspm=off',
    'pcie_port_pm=off',
]
lines = path.read_text().splitlines()
out = []
found = False
for line in lines:
    if line.startswith('LINUX_KERNEL_CMDLINE='):
        found = True
        prefix = 'LINUX_KERNEL_CMDLINE="'
        if line.startswith(prefix) and line.endswith('"'):
            body = line[len(prefix):-1]
        else:
            body = line.split('=', 1)[1].strip().strip('"')
        parts = body.split()
        for needle in needles:
            if needle not in parts:
                parts.append(needle)
        line = prefix + ' '.join(parts) + '"'
    out.append(line)
if not found:
    out.append('LINUX_KERNEL_CMDLINE="' + ' '.join(needles) + '"')
path.write_text('\n'.join(out) + '\n')
PY
    if command -v flash-kernel >/dev/null 2>&1; then
      run_cmd flash-kernel
    else
      warn "flash-kernel not found. NVMe kernel parameters were recorded but boot script was not regenerated."
    fi
  else
    warn "$flash_kernel_defaults not found. Skipping flash-kernel cmdline setup."
  fi
}

nvme_cmdline_patch_extlinux() {
  local extlinux_conf="/boot/extlinux/extlinux.conf"
  if [[ "$DRY_RUN" -eq 1 ]]; then
    echo "[DRY-RUN] append nvme_core.default_ps_max_latency_us=0 pcie_aspm=off pcie_port_pm=off to $extlinux_conf"
  elif [[ -f "$extlinux_conf" ]]; then
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
    info "Patched $extlinux_conf with NVMe/PCIe parameters"
  else
    warn "$extlinux_conf not found. Skipping extlinux cmdline setup."
  fi
}

apply_nvme_boot_mitigation() {
  info "Configuring conservative NVMe power policy for future boots"
  nvme_cmdline_patch_flash_kernel_defaults
  nvme_cmdline_patch_extlinux
}

install_fullnode_mount_guard() {
  local expected_source="$1"
  local docker_dropin_dir="/etc/systemd/system/docker.service.d"
  local docker_dropin_file="$docker_dropin_dir/require-fullnode.conf"
  local guard_script="/usr/local/sbin/fullnode-mount-guard.sh"
  local guard_service="/etc/systemd/system/fullnode-mount-guard.service"
  local guard_timer="/etc/systemd/system/fullnode-mount-guard.timer"

  info "Installing self-heal guard for fullnode mount"
  if [[ "$DRY_RUN" -eq 1 ]]; then
    echo "[DRY-RUN] create $docker_dropin_file"
    echo "[DRY-RUN] create $guard_script"
    echo "[DRY-RUN] create $guard_service"
    echo "[DRY-RUN] create $guard_timer"
    echo "[DRY-RUN] systemctl daemon-reload"
    echo "[DRY-RUN] systemctl enable --now fullnode-mount-guard.timer"
    return 0
  fi

  mkdir -p "$docker_dropin_dir"
  cat > "$docker_dropin_file" <<EOF
[Unit]
RequiresMountsFor=$DATA_DIR
EOF

  cat > "$guard_script" <<EOF
#!/bin/bash
set -euo pipefail
MOUNTPOINT="$DATA_DIR"
EXPECTED_SOURCE="$expected_source"
STATE_DIR="/var/lib/fullnode-mount-guard"
REBOOT_FLAG="\$STATE_DIR/reboot-attempted"
SNAPSHOT_DIR="\$STATE_DIR/snapshots"
mkdir -p "\$STATE_DIR" "\$SNAPSHOT_DIR"

log() { logger -t fullnode-mount-guard "\$1"; }
current_source() { findmnt -n -o SOURCE --target "\$MOUNTPOINT" 2>/dev/null || true; }
mount_is_healthy() { mountpoint -q "\$MOUNTPOINT" && [ "\$(current_source)" = "\$EXPECTED_SOURCE" ]; }

capture_snapshot() {
  local reason="\$1" ts snapshot
  ts="\$(date +%Y%m%d-%H%M%S)"
  snapshot="\$SNAPSHOT_DIR/\${ts}-\${reason}"
  mkdir -p "\$snapshot"
  {
    echo "timestamp=\$(date -Is)"
    echo "reason=\$reason"
    echo "mountpoint=\$MOUNTPOINT"
    echo "expected_source=\$EXPECTED_SOURCE"
    echo "current_source=\$(current_source)"
  } > "\$snapshot/meta.txt"
  cat /proc/cmdline > "\$snapshot/cmdline.txt" 2>/dev/null || true
  findmnt "\$MOUNTPOINT" > "\$snapshot/findmnt.txt" 2>&1 || true
  lsblk -f > "\$snapshot/lsblk.txt" 2>&1 || true
  journalctl -k -b --no-pager | grep -Ei 'nvme|EXT4-fs error|timeout|I/O error|blk_update_request|Buffer I/O' > "\$snapshot/kernel-storage.log" 2>&1 || true
}

if mount_is_healthy; then
  rm -f "\$REBOOT_FLAG"
  exit 0
fi

if mountpoint -q "\$MOUNTPOINT"; then
  log "\$MOUNTPOINT source is \$(current_source); expected \$EXPECTED_SOURCE; stopping docker and attempting remount"
  capture_snapshot wrong-source
else
  log "\$MOUNTPOINT is not mounted; stopping docker and attempting recovery"
  capture_snapshot not-mounted
fi

systemctl stop docker.service docker.socket >/dev/null 2>&1 || true
if [ -b "\$EXPECTED_SOURCE" ]; then
  if mountpoint -q "\$MOUNTPOINT"; then
    umount "\$MOUNTPOINT" >/dev/null 2>&1 || true
  fi
  mount "\$MOUNTPOINT" >/dev/null 2>&1 || true
  sleep 2
fi

if mount_is_healthy; then
  log "Recovered \$MOUNTPOINT with \$EXPECTED_SOURCE; restarting docker"
  rm -f "\$REBOOT_FLAG"
  systemctl start docker.socket docker.service >/dev/null 2>&1 || true
  exit 0
fi

if [ ! -e "\$REBOOT_FLAG" ]; then
  date -Is > "\$REBOOT_FLAG"
  log "Recovery failed; rebooting once to restore \$EXPECTED_SOURCE"
  systemctl reboot
  exit 0
fi

log "Recovery failed after one reboot attempt; keeping docker stopped to prevent root spillover"
exit 0
EOF
  chmod 0755 "$guard_script"

  cat > "$guard_service" <<EOF
[Unit]
Description=Auto-heal fullnode mount and protect Docker
After=local-fs.target

[Service]
Type=oneshot
ExecStart=$guard_script
EOF

  cat > "$guard_timer" <<'EOF'
[Unit]
Description=Periodic fullnode mount auto-heal guard

[Timer]
OnBootSec=30s
OnUnitActiveSec=15s
AccuracySec=5s
Unit=fullnode-mount-guard.service

[Install]
WantedBy=timers.target
EOF
  systemctl daemon-reload
  systemctl enable --now fullnode-mount-guard.timer >/dev/null 2>&1 || {
    err "Failed to enable fullnode-mount-guard.timer"
    return 1
  }
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
      if ! grep -qE "^${swapfile}[[:space:]]" /etc/fstab; then
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
# Patch: 0.4.5 — refresh the Umbrel system container image while preserving
# /mnt/fullnode data. This intentionally updates only the top-level Umbrel
# container; app containers and all data under /mnt/fullnode are left untouched.
# ---------------------------------------------------------------------------

inspect_umbrel_mount_source() {
  local destination="$1"
  docker inspect umbrel --format "{{range .Mounts}}{{if eq .Destination \"$destination\"}}{{.Source}}{{end}}{{end}}" 2>/dev/null || true
}

assert_fullnode_data_mount_safe() {
  local mount_source
  local umbrel_data_source
  local docker_sock_source

  command -v docker >/dev/null 2>&1 || {
    err "[0.4.5] Docker is not installed; cannot refresh Umbrel safely."
    return 1
  }

  docker inspect umbrel >/dev/null 2>&1 || {
    err "[0.4.5] Existing umbrel container not found; refusing to create a new one here."
    return 1
  }

  if ! findmnt --target "$DATA_DIR" >/dev/null 2>&1; then
    err "[0.4.5] $DATA_DIR is not mounted; refusing to touch the Umbrel container."
    err "[0.4.5] This prevents accidentally starting Umbrel with empty data on the root disk."
    return 1
  fi

  mount_source="$(findmnt --noheadings --output SOURCE --target "$DATA_DIR" | head -n1 | xargs || true)"
  if [[ "$mount_source" != /dev/nvme* ]]; then
    err "[0.4.5] $DATA_DIR is mounted from ${mount_source:-unknown}, not an NVMe partition; refusing to continue."
    return 1
  fi

  umbrel_data_source="$(inspect_umbrel_mount_source /data)"
  if [[ "$umbrel_data_source" != "$DATA_DIR" ]]; then
    err "[0.4.5] Existing umbrel /data mount is ${umbrel_data_source:-missing}, expected $DATA_DIR."
    err "[0.4.5] Refusing to refresh because user data preservation cannot be proven."
    return 1
  fi

  docker_sock_source="$(inspect_umbrel_mount_source /var/run/docker.sock)"
  if [[ "$docker_sock_source" != "/var/run/docker.sock" ]]; then
    err "[0.4.5] Existing umbrel docker.sock mount is ${docker_sock_source:-missing}; refusing to refresh."
    return 1
  fi
}

umbrel_image_id() {
  local image_ref="$1"
  docker image inspect "$image_ref" --format '{{.Id}}' 2>/dev/null || true
}

run_umbrel_container() {
  local image_ref="$1"
  run_cmd docker run -d --name umbrel --restart always -p 80:80 -v "$DATA_DIR:/data" -v /var/run/docker.sock:/var/run/docker.sock --stop-timeout 60 --pid=host --privileged "$image_ref"
}

rollback_umbrel_container() {
  local old_image_id="$1"
  warn "[0.4.5] New Umbrel container did not stabilize; rolling back to previous image."
  docker rm -f umbrel >/dev/null 2>&1 || true
  if docker run -d --name umbrel --restart always -p 80:80 -v "$DATA_DIR:/data" -v /var/run/docker.sock:/var/run/docker.sock --stop-timeout 60 --pid=host --privileged "$old_image_id" >/dev/null; then
    warn "[0.4.5] Rollback container started with previous image."
  else
    err "[0.4.5] Rollback failed. Data remains at $DATA_DIR; inspect with: docker logs umbrel"
    return 1
  fi
}

wait_for_umbrel_container() {
  local state
  for _ in {1..30}; do
    state="$(docker inspect --format='{{.State.Status}}' umbrel 2>/dev/null || true)"
    if [[ "$state" == "running" ]]; then
      return 0
    fi
    sleep 2
  done
  return 1
}

patch_umbrel_shutdown_source() {
  docker exec -i umbrel python3 - <<'PY_INNER'
from pathlib import Path
path = Path('/opt/umbreld/source/modules/system/system.ts')
text = path.read_text()
needle = 'export async function shutdown(): Promise<boolean> {'
start = text.index(needle)
end = text.index('\n}\n', start) + 3
replacement = """export async function shutdown(): Promise<boolean> {
	await $`docker update --restart=no ${os.hostname()}`
	await $`sh -lc ${'sleep 45; docker stop --time 15 "$(hostname)" >/dev/null 2>&1 &'}`

	return true
}
"""
current = text[start:end]
if 'sleep 45; docker stop --time 15 "$(hostname)"' not in current:
    text = text[:start] + replacement + text[end:]
    path.write_text(text)
PY_INNER
}

verify_umbrel_shutdown_source() {
  docker exec umbrel grep -q 'docker update --restart=no' /opt/umbreld/source/modules/system/system.ts
  docker exec umbrel grep -q 'sleep 45; docker stop --time 15 "$(hostname)"' /opt/umbreld/source/modules/system/system.ts
}

restore_umbrel_shutdown_ui() {
  docker exec -i umbrel python3 - <<'PY_INNER'
from pathlib import Path
patched = 'd.useEffect(()=>{F==="shutting-down"&&!f&&(p(!0),setTimeout(()=>m(!0),90*Gl))},[f,F,n])'
original = 'd.useEffect(()=>{F==="shutting-down"&&!f&&(I.isError||I.failureCount>0)&&(p(!0),setTimeout(()=>m(!0),30*Gl))},[f,F,I.failureCount,I.isError,n])'
for path in Path('/opt/umbreld/ui/assets').glob('*.js'):
    text = path.read_text(errors='ignore')
    if patched in text:
        path.write_text(text.replace(patched, original, 1))
index = Path('/opt/umbreld/ui/index.html')
html = index.read_text()
html = html.replace('/assets/index-7c0be990.js?v=m1s-shutdown-0.4.10', '/assets/index-7c0be990.js')
html = html.replace('/assets/index-7c0be990.js?v=m1s-shutdown-0.4.9', '/assets/index-7c0be990.js')
index.write_text(html)
PY_INNER
}

verify_umbrel_shutdown_ui_restored() {
  docker exec umbrel grep -R -q 'I.isError||I.failureCount>0' /opt/umbreld/ui/assets
  ! docker exec umbrel grep -q 'm1s-shutdown-0.4.10' /opt/umbreld/ui/index.html
}


install_umbrel_safe_shutdown() {
  info "Installing safe-to-unplug Umbrel shutdown behavior"

  if [[ "$DRY_RUN" -eq 1 ]]; then
    echo "[DRY-RUN] create $SAFE_SHUTDOWN_SERVICE"
    echo "[DRY-RUN] patch Umbrel shutdown() to disable Docker auto-restart and delay stopping the top-level umbrel container for the completion screen"
    echo "[DRY-RUN] systemctl daemon-reload"
    echo "[DRY-RUN] systemctl enable m1s-umbrel-autostart.service"
    return 0
  fi

  command -v docker >/dev/null 2>&1 || { err "Docker is required for safe shutdown setup."; return 1; }
  docker inspect umbrel >/dev/null 2>&1 || { err "umbrel container is required for safe shutdown setup."; return 1; }

  cat > "$SAFE_SHUTDOWN_SERVICE" <<EOF
[Unit]
Description=Restore Umbrel Docker autostart after safe-to-unplug shutdown
After=docker.service fullnode-mount-guard.service
Requires=docker.service
RequiresMountsFor=$DATA_DIR

[Service]
Type=oneshot
ExecStart=/usr/bin/docker update --restart=always umbrel
ExecStart=/usr/bin/docker start umbrel

[Install]
WantedBy=multi-user.target
EOF
  chmod 0644 "$SAFE_SHUTDOWN_SERVICE"

  patch_umbrel_shutdown_source
  verify_umbrel_shutdown_source || { err "Umbrel shutdown() safe-stop container patch could not be written"; return 1; }

  systemctl daemon-reload
  systemctl enable m1s-umbrel-autostart.service >/dev/null

  # Restart once so the running umbreld process loads the patched shutdown()
  # implementation. Existing apps are preserved and auto-start again normally.
  docker update --restart=always umbrel >/dev/null
  docker restart --time 60 umbrel >/dev/null
  wait_for_umbrel_container || { err "Umbrel did not restart after safe shutdown container patch."; return 1; }

  if ! verify_umbrel_shutdown_source; then
    warn "Umbrel shutdown patch was not present after restart; retrying patch and restart once."
    patch_umbrel_shutdown_source
    verify_umbrel_shutdown_source || { err "Umbrel shutdown() safe-stop container patch is missing after retry write"; return 1; }
    docker restart --time 60 umbrel >/dev/null
    wait_for_umbrel_container || { err "Umbrel did not restart after retrying safe shutdown container patch."; return 1; }
  fi
}

postcheck_umbrel_safe_shutdown() {
  if [[ "$DRY_RUN" -eq 1 ]]; then
    return 0
  fi
  [[ -f "$SAFE_SHUTDOWN_SERVICE" ]] || { err "m1s-umbrel-autostart.service is missing"; return 1; }
  systemctl is-enabled m1s-umbrel-autostart.service >/dev/null 2>&1 || { err "m1s-umbrel-autostart.service is not enabled"; return 1; }
  grep -q 'docker update --restart=always umbrel' "$SAFE_SHUTDOWN_SERVICE" || { err "m1s-umbrel-autostart.service does not restore restart policy"; return 1; }
  grep -q 'docker start umbrel' "$SAFE_SHUTDOWN_SERVICE" || { err "m1s-umbrel-autostart.service does not start Umbrel"; return 1; }
  verify_umbrel_shutdown_source || { err "Umbrel shutdown() safe-stop container patch is missing"; return 1; }
  local restart_policy
  restart_policy="$(docker inspect umbrel --format '{{.HostConfig.RestartPolicy.Name}}' 2>/dev/null || true)"
  [[ "$restart_policy" == "always" ]] || { err "umbrel restart policy should be always during normal operation, got ${restart_policy:-unknown}"; return 1; }
}

refresh_umbrel_system_container() {
  local old_image_id
  local new_image_id

  info "[0.4.5] Checking Umbrel system container image"
  assert_fullnode_data_mount_safe

  old_image_id="$(docker inspect umbrel --format '{{.Image}}')"

  if [[ "$DRY_RUN" -eq 1 ]]; then
    echo "[DRY-RUN] docker pull $UMBREL_IMAGE"
    echo "[DRY-RUN] if image changed: stop and recreate umbrel with $DATA_DIR:/data preserved"
    return 0
  fi

  info "[0.4.5] Updating Umbrel system image if needed; apps and data stay in $DATA_DIR"
  docker pull "$UMBREL_IMAGE" >/dev/null
  new_image_id="$(umbrel_image_id "$UMBREL_IMAGE")"

  if [[ -z "$new_image_id" ]]; then
    err "[0.4.5] Could not resolve pulled image ID for $UMBREL_IMAGE"
    return 1
  fi

  if [[ "$old_image_id" == "$new_image_id" ]]; then
    info "[0.4.5] Umbrel system container image is already current"
    return 0
  fi

  info "[0.4.5] Applying Umbrel system container update; web UI may be unavailable briefly"
  docker stop umbrel >/dev/null
  docker rm umbrel >/dev/null
  run_umbrel_container "$UMBREL_IMAGE" >/dev/null

  if ! wait_for_umbrel_container; then
    rollback_umbrel_container "$old_image_id"
    return 1
  fi

  if command -v curl >/dev/null 2>&1; then
    curl -fsS --max-time 10 http://127.0.0.1/ >/dev/null 2>&1 || warn "[0.4.5] Umbrel container is running, but HTTP is not ready yet"
  fi

  info "[0.4.5] Umbrel system container updated; existing apps and data were preserved"
}

patch_to_0_4_5() {
  refresh_umbrel_system_container
}

# ---------------------------------------------------------------------------
# Durable migration state and step runner.
# ---------------------------------------------------------------------------

update_install_state() {
  local action="$1"
  local step="${2:-}"
  local version="${3:-}"
  local message="${4:-}"
  if [[ "$DRY_RUN" -eq 1 ]]; then
    echo "[DRY-RUN] update $INSTALL_STATE_FILE (action=$action step=${step:-none} version=${version:-unchanged})"
    return 0
  fi

  mkdir -p "$INSTALL_STATE_DIR"
  local ts
  ts="$(date -Is)"
  python3 - "$INSTALL_STATE_FILE" "$action" "$step" "$version" "$message" "$ts" "$SCRIPT_VERSION" "$DATA_DIR" "$UMBREL_IMAGE" <<'PY'
import json, os, sys, tempfile

path, action, step, version, message, ts, script_version, data_dir, image = sys.argv[1:10]
base = {}
if os.path.exists(path):
    try:
        with open(path) as f:
            base = json.load(f)
    except Exception:
        base = {}

steps = base.get("applied_steps")
if not isinstance(steps, list):
    steps = []
base["applied_steps"] = steps
base["script_version"] = script_version
base["data_dir"] = base.get("data_dir") or data_dir
base["image"] = image
base["updated_at"] = ts
base["updated_by"] = "m1s-update-umbrel.sh"

if action == "started":
    base["in_progress_step"] = step
    base["failed_step"] = None
    base["last_error"] = None
elif action == "completed":
    if step and step not in steps:
        steps.append(step)
    if version:
        base["last_completed_version"] = version
    base["in_progress_step"] = None
    base["failed_step"] = None
    base["last_error"] = None
elif action == "failed":
    base["in_progress_step"] = None
    base["failed_step"] = step
    base["last_error"] = message or "migration step failed"
elif action == "finalized":
    if version:
        base["version"] = version
        base["host_version"] = version
    base["in_progress_step"] = None
    base["failed_step"] = None
    base["last_error"] = None
else:
    raise SystemExit(f"unknown state action: {action}")

d = os.path.dirname(path)
fd, tmp = tempfile.mkstemp(dir=d, prefix="installed.tmp.")
with os.fdopen(fd, "w") as f:
    json.dump(base, f, indent=2)
    f.write("\n")
os.chmod(tmp, 0o644)
os.rename(tmp, path)
PY
}

mark_step_started() { update_install_state started "$1" "" ""; }
mark_step_completed() { update_install_state completed "$1" "$2" ""; }
mark_step_failed() { update_install_state failed "$1" "" "$2"; }
finalize_install_state() { update_install_state finalized "" "$1" ""; }

is_step_applied() {
  local step="$1"
  [[ -f "$INSTALL_STATE_FILE" ]] || return 1
  python3 - "$INSTALL_STATE_FILE" "$step" <<'PY' 2>/dev/null
import json, sys
try:
    with open(sys.argv[1]) as f:
        data = json.load(f)
except Exception:
    sys.exit(1)
steps = data.get("applied_steps")
if isinstance(steps, list) and sys.argv[2] in steps:
    sys.exit(0)
sys.exit(1)
PY
}

step_from_version() { printf '%s\n' "${1%%_to_*}"; }
step_to_version() { printf '%s\n' "${1##*_to_}"; }
step_handler_name() { printf '%s\n' "${1//./_}"; }

require_function() {
  local name="$1"
  declare -F "$name" >/dev/null 2>&1 || {
    err "Missing updater function: $name"
    return 1
  }
}

global_preflight() {
  command -v python3 >/dev/null 2>&1 || { err "python3 is required for safe state updates."; return 1; }
  command -v docker >/dev/null 2>&1 || { err "Docker is not installed; refusing to update."; return 1; }
  [[ -d "$DATA_DIR" ]] || { err "$DATA_DIR does not exist; refusing to update."; return 1; }
  if [[ -f "$INSTALL_STATE_FILE" ]]; then
    python3 -m json.tool "$INSTALL_STATE_FILE" >/dev/null || { err "$INSTALL_STATE_FILE is not valid JSON."; return 1; }
  fi
}

build_migration_plan() {
  local current="$1"
  PLANNED_MIGRATIONS=()
  for step in "${MIGRATIONS[@]}"; do
    local to_version
    to_version="$(step_to_version "$step")"
    if version_lt "$current" "$to_version"; then
      PLANNED_MIGRATIONS+=("$step")
    fi
  done
}

run_migration_step() {
  local step="$1"
  local from_version to_version handler precheck_fn apply_fn postcheck_fn
  from_version="$(step_from_version "$step")"
  to_version="$(step_to_version "$step")"
  handler="$(step_handler_name "$step")"
  precheck_fn="precheck_$handler"
  apply_fn="apply_$handler"
  postcheck_fn="postcheck_$handler"

  if is_step_applied "$step"; then
    info "[$step] Already recorded; skipping"
    return 0
  fi

  require_function "$precheck_fn"
  require_function "$apply_fn"
  require_function "$postcheck_fn"

  info "[$step] Precheck"
  if ! "$precheck_fn"; then
    mark_step_failed "$step" "precheck failed"
    return 1
  fi

  mark_step_started "$step"
  info "[$step] Applying migration ($from_version -> $to_version)"
  if ! "$apply_fn"; then
    mark_step_failed "$step" "apply failed"
    return 1
  fi

  info "[$step] Postcheck"
  if ! "$postcheck_fn"; then
    mark_step_failed "$step" "postcheck failed"
    return 1
  fi

  mark_step_completed "$step" "$to_version"
  info "[$step] Completed"
}

precheck_common_canonical_install() {
  command -v docker >/dev/null 2>&1 || { err "Docker is required."; return 1; }
  docker inspect umbrel >/dev/null 2>&1 || { err "Existing umbrel container not found."; return 1; }
  findmnt --target "$DATA_DIR" >/dev/null 2>&1 || { err "$DATA_DIR is not mounted."; return 1; }
}

precheck_0_1_0_to_0_2_0() { precheck_common_canonical_install; }
apply_0_1_0_to_0_2_0() {
  local mount_source
  mount_source="$(findmnt --noheadings --output SOURCE --target "$DATA_DIR" | head -n1 | xargs || true)"
  [[ -n "$mount_source" ]] || { err "Could not determine $DATA_DIR source."; return 1; }
  apply_nvme_boot_mitigation
  install_fullnode_mount_guard "$mount_source"
}
postcheck_0_1_0_to_0_2_0() {
  if [[ "$DRY_RUN" -eq 1 ]]; then
    return 0
  fi
  [[ -f /etc/systemd/system/fullnode-mount-guard.service ]] || { err "fullnode-mount-guard.service is missing"; return 1; }
  [[ -f /etc/systemd/system/fullnode-mount-guard.timer ]] || { err "fullnode-mount-guard.timer is missing"; return 1; }
  systemctl is-enabled fullnode-mount-guard.timer >/dev/null 2>&1 || { err "fullnode-mount-guard.timer is not enabled"; return 1; }
  systemctl is-active fullnode-mount-guard.timer >/dev/null 2>&1 || { err "fullnode-mount-guard.timer is not active"; return 1; }
  findmnt --target "$DATA_DIR" >/dev/null 2>&1 || { err "$DATA_DIR is not mounted after guard migration"; return 1; }
}

precheck_0_2_0_to_0_3_0() { precheck_common_canonical_install; }
apply_0_2_0_to_0_3_0() {
  wait_for_apt_locks
  patch_to_0_3_0
}
postcheck_0_2_0_to_0_3_0() { [[ "$DRY_RUN" -eq 1 ]] || [[ -d "$INSTALL_STATE_DIR" ]] || mkdir -p "$INSTALL_STATE_DIR"; }

precheck_0_3_0_to_0_4_0() { precheck_common_canonical_install; }
apply_0_3_0_to_0_4_0() { patch_to_0_4_0; }
postcheck_0_3_0_to_0_4_0() {
  findmnt --target "$DATA_DIR" >/dev/null 2>&1 || { err "$DATA_DIR is not mounted after 0.4.0 migration"; return 1; }
  command -v docker >/dev/null 2>&1 || { err "Docker command missing after 0.4.0 migration"; return 1; }
}

precheck_0_4_0_to_0_4_1() { precheck_common_canonical_install; }
apply_0_4_0_to_0_4_1() { patch_to_0_4_1; }
postcheck_0_4_0_to_0_4_1() { [[ "$DRY_RUN" -eq 1 ]] || [[ -f /etc/systemd/system/nvme-timeout-snapshot.timer ]]; }

precheck_0_4_1_to_0_4_2() { precheck_common_canonical_install; }
apply_0_4_1_to_0_4_2() {
  wait_for_apt_locks
  patch_to_0_4_2
}
postcheck_0_4_1_to_0_4_2() {
  if [[ "$DRY_RUN" -eq 1 ]]; then
    return 0
  fi
  command -v smartctl >/dev/null 2>&1 || { err "smartctl is required after 0.4.2 migration."; return 1; }
  command -v lspci >/dev/null 2>&1 || warn "lspci is still unavailable after diagnostic migration"
  command -v nvme >/dev/null 2>&1 || warn "nvme-cli is still unavailable after diagnostic migration"
}

precheck_0_4_2_to_0_4_3() { precheck_common_canonical_install; }
apply_0_4_2_to_0_4_3() { info "[0.4.3] Documentation-only release; recording migration history"; }
postcheck_0_4_2_to_0_4_3() { precheck_common_canonical_install; }

precheck_0_4_3_to_0_4_4() { precheck_common_canonical_install; }
apply_0_4_3_to_0_4_4() { info "[0.4.4] Verification-only release; recording migration history"; }
postcheck_0_4_3_to_0_4_4() { precheck_common_canonical_install; }

precheck_0_4_4_to_0_4_5() { assert_fullnode_data_mount_safe; }
apply_0_4_4_to_0_4_5() { patch_to_0_4_5; }
postcheck_0_4_4_to_0_4_5() {
  assert_fullnode_data_mount_safe || return 1
  wait_for_umbrel_container || { err "Umbrel container did not become running after 0.4.5 migration"; return 1; }
}

precheck_0_4_5_to_0_4_6() { precheck_common_canonical_install; }
apply_0_4_5_to_0_4_6() { info "[0.4.6] Migration-runner release; recording migration history"; }
postcheck_0_4_5_to_0_4_6() { precheck_common_canonical_install; }

precheck_0_4_6_to_0_4_7() { precheck_common_canonical_install; }
apply_0_4_6_to_0_4_7() { install_umbrel_safe_shutdown; }
postcheck_0_4_6_to_0_4_7() { postcheck_umbrel_safe_shutdown; }

precheck_0_4_7_to_0_4_8() { precheck_common_canonical_install; }
apply_0_4_7_to_0_4_8() { install_umbrel_safe_shutdown; }
postcheck_0_4_7_to_0_4_8() { postcheck_umbrel_safe_shutdown; }

precheck_0_4_8_to_0_4_9() { precheck_common_canonical_install; }
apply_0_4_8_to_0_4_9() { install_umbrel_safe_shutdown; }
postcheck_0_4_8_to_0_4_9() { postcheck_umbrel_safe_shutdown; }

precheck_0_4_9_to_0_4_10() { precheck_common_canonical_install; }
apply_0_4_9_to_0_4_10() { install_umbrel_safe_shutdown; }
postcheck_0_4_9_to_0_4_10() { postcheck_umbrel_safe_shutdown; }

precheck_0_4_10_to_0_4_11() { precheck_common_canonical_install; }
apply_0_4_10_to_0_4_11() { install_umbrel_safe_shutdown; restore_umbrel_shutdown_ui; }
postcheck_0_4_10_to_0_4_11() { postcheck_umbrel_safe_shutdown; verify_umbrel_shutdown_ui_restored; }

precheck_0_4_11_to_0_4_12() { precheck_common_canonical_install; }
apply_0_4_11_to_0_4_12() { install_umbrel_safe_shutdown; }
postcheck_0_4_11_to_0_4_12() { postcheck_umbrel_safe_shutdown; }

precheck_0_4_12_to_0_4_13() { precheck_common_canonical_install; }
apply_0_4_12_to_0_4_13() { info "[0.4.13] Documentation-only release; recording migration history"; }
postcheck_0_4_12_to_0_4_13() { precheck_common_canonical_install; }

precheck_0_4_13_to_0_4_14() { precheck_common_canonical_install; }
apply_0_4_13_to_0_4_14() { info "[0.4.14] Fresh installer interactive abort fix; recording migration history"; }
postcheck_0_4_13_to_0_4_14() { precheck_common_canonical_install; }

# ---------------------------------------------------------------------------
# Main flow
# ---------------------------------------------------------------------------

main() {
  parse_args "$@"
  require_root

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

build_migration_plan "$CURRENT_VERSION"

if [[ "${#PLANNED_MIGRATIONS[@]}" -eq 0 ]]; then
  echo "No migrations needed. Host is already at $CURRENT_VERSION (>= $TARGET_VERSION)."
  exit 0
fi

echo "Planned migrations:"
for step in "${PLANNED_MIGRATIONS[@]}"; do
  echo "  - $step"
done
echo

if [[ "$CHECK_ONLY" -eq 1 ]]; then
  echo "--check specified; not applying anything."
  exit 0
fi

global_preflight

for step in "${PLANNED_MIGRATIONS[@]}"; do
  if ! run_migration_step "$step"; then
    err "Migration failed at $step. Final version was not recorded as $TARGET_VERSION."
    err "Fix the issue, then rerun this script; completed steps will be skipped."
    exit 1
  fi
done

finalize_install_state "$TARGET_VERSION"

echo
echo "==========================================="
echo "  Update complete."
echo "==========================================="
echo "Host is now at version: $TARGET_VERSION"
echo
  if [[ "$DRY_RUN" -eq 1 ]]; then
    echo "[DRY-RUN] No changes were actually made."
  fi
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
