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
#   --skip-sync    Do not refresh this repository from origin/main before updating.
#   --version      Print script version and exit.
#   -h, --help     Show this help.

SCRIPT_VERSION="0.5.29"
INSTALL_STATE_DIR="/etc/umbrel-recovery"
INSTALL_STATE_FILE="$INSTALL_STATE_DIR/installed.json"
DATA_DIR="/mnt/fullnode"
HOST_DATA_ALIAS="/data"
FSTAB_FILE="${FSTAB_FILE:-/etc/fstab}"
FULLNODE_FSTAB_OPTIONS="defaults,auto,exec,rw,nofail,x-systemd.device-timeout=10s"
DATA_ALIAS_FSTAB_OPTIONS="bind,nofail,x-systemd.requires-mounts-for=$DATA_DIR"
UMBREL_IMAGE="dockurr/umbrel:1.7.4@sha256:e00c07a838ce3b50641a0a984abe155a7223abacab3426a55409edf21b6e0124"
SAFE_SHUTDOWN_SERVICE="/etc/systemd/system/m1s-umbrel-autostart.service"
OFFICIAL_REPO_SLUG="dongguri-jun/odroid-m1s-umbrel-recovery"

DRY_RUN=0
CHECK_ONLY=0
AUTO_SYNC=1
SELF_SYNC_REEXECED=0
APP_STOP_TIMEOUT_SECONDS=300
STOPPED_APP_CONTAINERS=()
APP_CONTAINERS_STOPPED=0
LEGACY_SYSTEM_CONTAINERS=(auth tor_proxy)
CANDIDATE_SYSTEM_CONTAINERS=(umbrel_auth umbrel_tor_proxy)
ALL_KNOWN_SYSTEM_CONTAINERS=("${LEGACY_SYSTEM_CONTAINERS[@]}" "${CANDIDATE_SYSTEM_CONTAINERS[@]}")

# shellcheck source=scripts/m1s-support-policy.sh
source "$(dirname "${BASH_SOURCE[0]}")/m1s-support-policy.sh"
# shellcheck source=scripts/m1s-backup-retention.sh
source "$(dirname "${BASH_SOURCE[0]}")/m1s-backup-retention.sh"
# shellcheck source=scripts/m1s-avahi-mdns.sh
source "$(dirname "${BASH_SOURCE[0]}")/m1s-avahi-mdns.sh"
TOR_PROXY_IMAGE="ghcr.io/getumbrel/tor:0.4.9.11"
CANDIDATE_READINESS_ATTEMPTS=30
CANDIDATE_RETRY_DELAY_SECONDS=2
UMBREL_TRANSACTION_ACTIVE=0
UMBREL_TRANSACTION_MUTATED=0
UMBREL_TRANSACTION_TARGET_IMAGE_ID=""
UMBREL_TRANSACTION_FAILURE_MESSAGE=""
UMBREL_TRANSACTION_APP_CONTAINERS=()
LEGACY_INCUS_PACKAGES=(incus incus-base incus-client lxd-agent-loader)
LEGACY_INCUS_SERVICES=(incus.service incus.socket incus-lxcfs.service snap.lxd.daemon.service snap.lxd.daemon.unix.socket)
LEGACY_INCUS_PATHS=(/var/lib/incus /var/lib/lxd /var/snap/lxd /root/.cache/incus /root/.config/incus)

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
  "0.4.14_to_0.4.15"
  "0.4.15_to_0.4.16"
  "0.4.16_to_0.4.17"
  "0.4.17_to_0.4.18"
  "0.4.18_to_0.5.0"
  "0.5.0_to_0.5.1"
  "0.5.1_to_0.5.2"
  "0.5.2_to_0.5.3"
  "0.5.3_to_0.5.4"
  "0.5.4_to_0.5.5"
  "0.5.5_to_0.5.6"
  "0.5.6_to_0.5.7"
  "0.5.7_to_0.5.8"
  "0.5.8_to_0.5.9"
  "0.5.9_to_0.5.10"
  "0.5.10_to_0.5.11"
  "0.5.11_to_0.5.12"
  "0.5.12_to_0.5.13"
  "0.5.13_to_0.5.14"
  "0.5.14_to_0.5.15"
  "0.5.15_to_0.5.16"
  "0.5.16_to_0.5.17"
  "0.5.17_to_0.5.18"
  "0.5.18_to_0.5.19"
  "0.5.19_to_0.5.20"
  "0.5.20_to_0.5.21"
  "0.5.21_to_0.5.22"
  "0.5.22_to_0.5.23"
  "0.5.23_to_0.5.24"
  "0.5.24_to_0.5.25"
  "0.5.25_to_0.5.26"
  "0.5.26_to_0.5.27"
  "0.5.27_to_0.5.28"
  "0.5.28_to_0.5.29"
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

script_path() {
  local source_path="${BASH_SOURCE[0]}"
  if [[ "$source_path" == */* ]]; then
    printf '%s/%s\n' "$(cd "$(dirname "$source_path")" && pwd -P)" "$(basename "$source_path")"
  else
    command -v -- "$source_path"
  fi
}

script_dir() {
  cd "$(dirname "$(script_path)")" && pwd -P
}

repo_root_from_script() {
  if [[ -n "${AUTO_SYNC_REPO_ROOT_OVERRIDE:-}" ]]; then
    cd "$AUTO_SYNC_REPO_ROOT_OVERRIDE" && pwd -P
    return 0
  fi

  local dir
  dir="$(script_dir)"
  cd "$dir/.." && pwd -P
}

origin_url_is_official() {
  local url="$1"
  case "$url" in
    "https://github.com/$OFFICIAL_REPO_SLUG"|\
    "https://github.com/$OFFICIAL_REPO_SLUG.git"|\
    "git@github.com:$OFFICIAL_REPO_SLUG.git"|\
    "ssh://git@github.com/$OFFICIAL_REPO_SLUG.git")
      return 0
      ;;
  esac
  return 1
}

sync_repository_to_origin_main() {
  [[ "$AUTO_SYNC" -eq 1 ]] || return 0

  local repo_root current_head origin_head updated_script safe_directory origin_url
  repo_root="$(repo_root_from_script)"

  if [[ ! -d "$repo_root/.git" ]]; then
    warn "Repository auto-sync skipped: $repo_root is not a git checkout."
    warn "Continuing with the updater script already present on this device."
    return 0
  fi

  if ! command -v git >/dev/null 2>&1; then
    err "Repository auto-sync requires git, but git is not installed."
    return 1
  fi

  if [[ "$DRY_RUN" -eq 1 ]]; then
    echo "[DRY-RUN] git -c safe.directory=$repo_root -C $repo_root fetch origin"
    echo "[DRY-RUN] git -c safe.directory=$repo_root -C $repo_root reset --hard origin/main"
    return 0
  fi

  info "Syncing updater repository to origin/main before checking host migrations..."

  safe_directory="safe.directory=$repo_root"
  current_head="$(git -c "$safe_directory" -C "$repo_root" rev-parse HEAD 2>/dev/null || printf 'unknown')"

  if ! origin_url="$(git -c "$safe_directory" -C "$repo_root" remote get-url origin 2>/dev/null)"; then
    err "Repository auto-sync failed: git remote 'origin' is missing."
    err "Run this updater from the official odroid-m1s-umbrel-recovery clone."
    return 1
  fi

  if ! origin_url_is_official "$origin_url"; then
    err "Repository auto-sync refused: origin does not point to the official repository."
    err "Current origin: $origin_url"
    err "Expected: https://github.com/$OFFICIAL_REPO_SLUG.git"
    return 1
  fi

  git -c "$safe_directory" -C "$repo_root" fetch origin || {
    err "Repository auto-sync failed while fetching origin/main. Check network connectivity, then rerun this updater."
    return 1
  }

  origin_head="$(git -c "$safe_directory" -C "$repo_root" rev-parse origin/main 2>/dev/null || true)"
  if [[ -z "$origin_head" ]]; then
    err "Repository auto-sync failed: origin/main was not found after fetch."
    return 1
  fi

  git -c "$safe_directory" -C "$repo_root" reset --hard origin/main || {
    err "Repository auto-sync failed while resetting to origin/main."
    return 1
  }

  if [[ "$current_head" != "$origin_head" && "$SELF_SYNC_REEXECED" -eq 0 ]]; then
    updated_script="$repo_root/scripts/$(basename "$(script_path)")"
    if [[ -f "$updated_script" ]]; then
      info "Repository changed during auto-sync; restarting the latest updater script."
      SELF_SYNC_REEXECED=1 exec bash "$updated_script" --skip-sync "$@"
    fi
  fi
}

ufw_is_active() {
  command -v ufw >/dev/null 2>&1 || return 1
  ufw status 2>/dev/null | grep -Fxq "Status: active"
}

disable_ufw_for_umbrel() {
  if ! command -v ufw >/dev/null 2>&1; then
    info "UFW is not installed; nothing to disable for Umbrel networking."
    return 0
  fi

  if [[ "$DRY_RUN" -eq 1 ]]; then
    echo "[DRY-RUN] if UFW is active, disable it to match Umbrel Home-style Docker networking"
    return 0
  fi

  if ! ufw_is_active; then
    info "UFW is already inactive; Umbrel networking is not being blocked by host firewall rules."
    return 0
  fi

  info "Disabling UFW to avoid interfering with Umbrel Docker networking"
  ufw --force disable >/dev/null || { err "Failed to disable UFW; Umbrel app networking may remain blocked by host firewall rules."; return 1; }
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
  --skip-sync    Do not refresh this repository from origin/main before updating.
  --version      Print script version and exit.
  -h, --help     Show this help.

Notes:
  - Run this on a host that was already set up with m1s-clean-install-umbrel.sh.
  - The updater never formats disks and never deletes user data. It may refresh
    the Umbrel system container only after validating that /data is backed by
    the existing /mnt/fullnode data mount.
  - By default, the updater first refreshes this repository to origin/main, so
    the same command keeps using the latest published script.
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
      --skip-sync)
        AUTO_SYNC=0
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

is_numeric_version() {
  [[ "$1" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]
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

read_install_state_value() {
  local key="$1"
  [[ -f "$INSTALL_STATE_FILE" ]] || return 1
  python3 - "$INSTALL_STATE_FILE" "$key" <<'PY' 2>/dev/null
import json, sys
try:
    with open(sys.argv[1]) as f:
        data = json.load(f)
    value = data.get(sys.argv[2])
    if isinstance(value, str) and value:
        print(value)
        sys.exit(0)
except Exception:
    pass
sys.exit(1)
PY
}

fstab_has_mountpoint() {
  local mountpoint="$1"
  awk -v mountpoint="$mountpoint" '
    $0 !~ /^[[:space:]]*#/ && NF >= 2 && $2 == mountpoint { found = 1 }
    END { exit found ? 0 : 1 }
  ' "$FSTAB_FILE"
}

fstab_mount_source_for() {
  local mountpoint="$1"
  awk -v mountpoint="$mountpoint" '
    $0 !~ /^[[:space:]]*#/ && NF >= 2 && $2 == mountpoint { print $1; exit }
  ' "$FSTAB_FILE"
}

source_matches_partition_or_uuid() {
  local source="$1"
  local partition="$2"
  local uuid="$3"
  [[ -n "$partition" && "$source" == "$partition" ]] && return 0
  [[ -n "$uuid" && "$source" == "UUID=$uuid" ]] && return 0
  [[ -n "$uuid" && "$source" == "UUID=\"$uuid\"" ]] && return 0
  return 1
}

target_partition_exists() {
  local partition="$1"
  [[ -b "$partition" ]] && return 0
  [[ "${M1S_TEST_ALLOW_NON_BLOCK_TARGET:-0}" -eq 1 && -e "$partition" ]] && return 0
  return 1
}

target_partition_uuid() {
  local partition="$1"
  if [[ -n "${M1S_TEST_TARGET_UUID:-}" ]]; then
    printf '%s\n' "$M1S_TEST_TARGET_UUID"
    return 0
  fi
  blkid -s UUID -o value "$partition" 2>/dev/null
}

ensure_fullnode_mount_from_state() {
  local mode="${1:-repair}"
  local target_partition state_data_dir target_uuid existing_source repaired=0

  [[ -f "$INSTALL_STATE_FILE" ]] || return 0
  target_partition="$(read_install_state_value target_partition || true)"
  state_data_dir="$(read_install_state_value data_dir || true)"
  [[ -n "$state_data_dir" ]] || state_data_dir="$DATA_DIR"

  if [[ "$state_data_dir" != "$DATA_DIR" ]]; then
    warn "Install state data_dir is $state_data_dir, expected $DATA_DIR; skipping automatic fstab repair."
    return 0
  fi

  if [[ -z "$target_partition" ]]; then
    warn "Install state has no target_partition; skipping automatic fstab repair."
    return 0
  fi

  if ! target_partition_exists "$target_partition"; then
    warn "Install state target partition $target_partition is not currently visible; skipping automatic fstab repair."
    return 0
  fi

  target_uuid="$(target_partition_uuid "$target_partition" || true)"
  if [[ -z "$target_uuid" ]]; then
    warn "Could not determine UUID for $target_partition; skipping automatic fstab repair."
    return 0
  fi

  if fstab_has_mountpoint "$DATA_DIR"; then
    existing_source="$(fstab_mount_source_for "$DATA_DIR" || true)"
    if ! source_matches_partition_or_uuid "$existing_source" "$target_partition" "$target_uuid"; then
      err "$DATA_DIR is already present in /etc/fstab but points to $existing_source, not $target_partition."
      err "Refusing automatic repair to avoid mounting the wrong disk."
      return 1
    fi
  else
    warn "$DATA_DIR is missing from /etc/fstab; restoring it from $INSTALL_STATE_FILE."
    if [[ "$mode" == "check" || "$DRY_RUN" -eq 1 ]]; then
      echo "[DRY-RUN] backup /etc/fstab and append UUID=$target_uuid $DATA_DIR ext4 $FULLNODE_FSTAB_OPTIONS 0 0"
    else
      m1s_backup_file_with_retention "$FSTAB_FILE" '.bak.update-repair' '+%Y%m%d%H%M%S'
      printf 'UUID=%s\t%s\text4\t%s\t0\t0\n' "$target_uuid" "$DATA_DIR" "$FULLNODE_FSTAB_OPTIONS" >> "$FSTAB_FILE"
      if [[ "$FSTAB_FILE" == "/etc/fstab" ]]; then
        systemctl daemon-reload || true
      fi
      repaired=1
    fi
  fi

  if ! findmnt --target "$DATA_DIR" >/dev/null 2>&1; then
    warn "$DATA_DIR is not mounted; mounting $target_partition."
    if [[ "$mode" == "check" || "$DRY_RUN" -eq 1 ]]; then
      echo "[DRY-RUN] mkdir -p $DATA_DIR"
      echo "[DRY-RUN] mount $DATA_DIR"
    else
      mkdir -p "$DATA_DIR"
      mount "$DATA_DIR"
      repaired=1
    fi
  fi

  if [[ "$mode" != "check" && "$DRY_RUN" -eq 0 && "$repaired" -eq 1 ]]; then
    if command -v systemctl >/dev/null 2>&1; then
      systemctl start docker >/dev/null 2>&1 || warn "Docker did not start automatically after $DATA_DIR repair; continuing with updater checks."
    fi
    info "$DATA_DIR fstab/mount state repaired from installed.json."
  fi
}

nvme_cmdline_patch_flash_kernel_defaults() {
  local flash_kernel_defaults="/etc/default/flash-kernel"
  if [[ "$DRY_RUN" -eq 1 ]]; then
    echo "[DRY-RUN] backup $flash_kernel_defaults"
    echo "[DRY-RUN] append nvme_core.default_ps_max_latency_us=0 pcie_aspm=off pcie_port_pm=off to LINUX_KERNEL_CMDLINE"
    echo "[DRY-RUN] flash-kernel"
  elif [[ -f "$flash_kernel_defaults" ]]; then
    m1s_backup_file_with_retention "$flash_kernel_defaults" '.bak' '+%s'
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
    m1s_backup_file_with_retention "$extlinux_conf" '.bak' '+%s'
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

remove_pwm_fan_config() {
  local config_ini="/boot/config.ini"
  local result

  if [[ "$DRY_RUN" -eq 1 ]]; then
    echo "[DRY-RUN] remove PWM fan overlay settings from $config_ini if present"
    return 0
  fi

  if [[ ! -f "$config_ini" ]]; then
    info "$config_ini not found; skipping PWM fan cleanup"
    return 0
  fi

  m1s_backup_file_with_retention "$config_ini" '.bak' '+%s'
  result="$(PWM_CONFIG_FILE="$config_ini" python3 - <<'PY'
from pathlib import Path
import os
import re

path = Path(os.environ['PWM_CONFIG_FILE'])
lines = path.read_text().splitlines()
out = []
changed = False
in_overlay_pwm = False

for line in lines:
    stripped = line.strip()

    if stripped.startswith('[') and stripped.endswith(']'):
        if stripped == '[overlay_pwm]':
            changed = True
            in_overlay_pwm = True
            continue
        in_overlay_pwm = False
        out.append(line)
        continue

    if in_overlay_pwm:
        changed = True
        continue

    if re.match(r'^\s*overlay_profile\s*=\s*pwm\s*$', line):
        changed = True
        continue

    if re.match(r'^\s*overlays\s*=', line):
        key, value = line.split('=', 1)
        raw_value = value.strip()
        quoted = raw_value.startswith('"') and raw_value.endswith('"')
        body = raw_value[1:-1] if quoted else raw_value
        tokens = body.split()
        filtered = [token for token in tokens if token not in {'pwm1', 'pwm2'}]
        if filtered != tokens:
            changed = True
            rebuilt = ' '.join(filtered)
            out.append(f'{key}="{rebuilt}"' if quoted else f'{key}={rebuilt}')
            continue

    out.append(line)

if changed:
    path.write_text('\n'.join(out).rstrip() + '\n')
    print('changed')
else:
    print('unchanged')
PY
)"

  if [[ "$result" == "changed" ]]; then
    info "Removed PWM fan overlay settings from $config_ini"
  else
    info "PWM fan overlay settings already absent in $config_ini"
  fi
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
# Patch: 0.3.0 — install Avahi and apply the current managed mDNS policy.
# ---------------------------------------------------------------------------

patch_to_0_3_0() {
  info "[0.3.0] Applying the managed Avahi and umbrel.local configuration"

  # Ensure avahi + libnss-mdns are present. If the 0.2.0 installer already
  # added them this is a no-op.
  if ! dpkg -s avahi-daemon >/dev/null 2>&1; then
    info "[0.3.0] Installing avahi-daemon avahi-utils libnss-mdns"
    if [[ "$DRY_RUN" -eq 1 ]]; then
      echo "[DRY-RUN] apt-get install -y avahi-daemon avahi-utils libnss-mdns"
    else
      if ! DEBIAN_FRONTEND=noninteractive apt-get install -y \
        avahi-daemon avahi-utils libnss-mdns >/dev/null 2>&1; then
        err "[0.3.0] Failed to install Avahi packages"
        return 1
      fi
    fi
  fi

  m1s_configure_avahi_mdns
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

install_fstrim_dropin() {
  local dropin_dir="/etc/systemd/system/fstrim.service.d"
  local dropin_file="$dropin_dir/m1s-no-syscallfilter.conf"
  local host_version="unknown"

  if [[ -r /etc/os-release ]]; then
    # shellcheck disable=SC1091
    source /etc/os-release
    host_version="${VERSION_ID:-unknown}"
  fi

  if [[ "$host_version" != "22.04" ]]; then
    info "Skipping fstrim.service compatibility drop-in on Ubuntu ${host_version}"
    return 0
  fi

  info "Installing ODROID M1S fstrim.service compatibility drop-in"
  if [[ "$DRY_RUN" -eq 1 ]]; then
    echo "[DRY-RUN] create $dropin_file"
    echo "[DRY-RUN] systemctl daemon-reload"
    echo "[DRY-RUN] systemctl reset-failed fstrim.service"
    echo "[DRY-RUN] systemctl start fstrim.service"
    return 0
  fi

  mkdir -p "$dropin_dir"
  cat > "$dropin_file" <<'EOF'
[Service]
# ODROID M1S (aarch64 + Ubuntu 22.04) ships a SystemCallFilter that kills
# fstrim with SIGSYS on every run. fstrim is root-only, triggered only by
# fstrim.timer, and operates on already-mounted local filesystems. Disabling
# the syscall filter here restores weekly TRIM without expanding any
# externally reachable attack surface.
SystemCallFilter=
SystemCallErrorNumber=
EOF
  chmod 0644 "$dropin_file"

  systemctl daemon-reload
  systemctl reset-failed fstrim.service >/dev/null 2>&1 || true
  systemctl start fstrim.service >/dev/null 2>&1 || warn "Failed to start fstrim.service after installing compatibility drop-in"
  info "Installed fstrim.service compatibility drop-in"
}

patch_to_0_4_0() {
  local extlinux_conf="/boot/extlinux/extlinux.conf"
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

  info "[0.4.0] Applying the managed Avahi and umbrel.local configuration"
  m1s_configure_avahi_mdns || return 1

  # On ODROID M1S the u-boot loader reads /boot/extlinux/extlinux.conf directly
  # for the kernel cmdline, so NVMe/PCIe hardening parameters in
  # /etc/default/flash-kernel are not applied on the next boot. Patch the
  # extlinux append line so the hardening actually takes effect.
  if [[ -f "$extlinux_conf" ]]; then
    m1s_backup_file_with_retention "$extlinux_conf" '.bak' '+%s'
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
      m1s_backup_file_with_retention "$docker_json" '.bak' '+%s'
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

paths_same_inode() {
  local first="$1"
  local second="$2"
  [[ -e "$first" && -e "$second" ]] || return 1
  [[ "$(stat -c '%d:%i' "$first")" == "$(stat -c '%d:%i' "$second")" ]]
}

path_has_entries() {
  local path="$1"
  [[ -d "$path" ]] || return 1
  find "$path" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null | grep -q .
}

host_data_alias_ready() {
  findmnt --target "$HOST_DATA_ALIAS" >/dev/null 2>&1 && paths_same_inode "$HOST_DATA_ALIAS" "$DATA_DIR"
}

umbrel_container_data_source() {
  if host_data_alias_ready; then
    printf '%s\n' "$HOST_DATA_ALIAS"
  else
    printf '%s\n' "$DATA_DIR"
  fi
}

ensure_host_data_alias() {
  local mode="${1:-repair}"
  local existing_source

  findmnt --target "$DATA_DIR" >/dev/null 2>&1 || { err "$DATA_DIR is not mounted; refusing to create $HOST_DATA_ALIAS alias."; return 1; }

  if [[ -L "$HOST_DATA_ALIAS" ]]; then
    err "$HOST_DATA_ALIAS is a symlink; refusing to use it for Umbrel data. A real bind mount is required."
    return 1
  fi

  if fstab_has_mountpoint "$HOST_DATA_ALIAS"; then
    existing_source="$(fstab_mount_source_for "$HOST_DATA_ALIAS" || true)"
    if [[ "$existing_source" != "$DATA_DIR" ]]; then
      err "$HOST_DATA_ALIAS is already present in $FSTAB_FILE but points to $existing_source, not $DATA_DIR."
      err "Refusing to continue to avoid writing Umbrel data to the wrong location."
      return 1
    fi
  elif [[ "$mode" == "check" || "$DRY_RUN" -eq 1 ]]; then
    echo "[DRY-RUN] backup $FSTAB_FILE and append $DATA_DIR $HOST_DATA_ALIAS none $DATA_ALIAS_FSTAB_OPTIONS 0 0"
  else
    m1s_backup_file_with_retention "$FSTAB_FILE" '.bak.data-alias' '+%Y%m%d%H%M%S'
    printf '%s\t%s\tnone\t%s\t0\t0\n' "$DATA_DIR" "$HOST_DATA_ALIAS" "$DATA_ALIAS_FSTAB_OPTIONS" >> "$FSTAB_FILE"
    if [[ "$FSTAB_FILE" == "/etc/fstab" ]]; then
      systemctl daemon-reload || true
    fi
  fi

  if findmnt --target "$HOST_DATA_ALIAS" >/dev/null 2>&1; then
    paths_same_inode "$HOST_DATA_ALIAS" "$DATA_DIR" || { err "$HOST_DATA_ALIAS is mounted but does not point to $DATA_DIR."; return 1; }
    return 0
  fi

  if [[ -e "$HOST_DATA_ALIAS" && ! -d "$HOST_DATA_ALIAS" ]]; then
    err "$HOST_DATA_ALIAS exists but is not a directory; refusing to replace it."
    return 1
  fi

  if [[ -d "$HOST_DATA_ALIAS" ]] && path_has_entries "$HOST_DATA_ALIAS"; then
    err "$HOST_DATA_ALIAS exists and is not empty while not mounted. Refusing to hide unrelated files."
    return 1
  fi

  if [[ "$mode" == "check" || "$DRY_RUN" -eq 1 ]]; then
    echo "[DRY-RUN] mkdir -p $HOST_DATA_ALIAS"
    echo "[DRY-RUN] mount --bind $DATA_DIR $HOST_DATA_ALIAS"
    return 0
  fi

  mkdir -p "$HOST_DATA_ALIAS"
  mount --bind "$DATA_DIR" "$HOST_DATA_ALIAS"
  paths_same_inode "$HOST_DATA_ALIAS" "$DATA_DIR" || { err "$HOST_DATA_ALIAS bind mount does not match $DATA_DIR after mount."; return 1; }
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
  if [[ "$umbrel_data_source" != "$DATA_DIR" && "$umbrel_data_source" != "$HOST_DATA_ALIAS" ]]; then
    err "[0.4.5] Existing umbrel /data mount is ${umbrel_data_source:-missing}, expected $DATA_DIR or $HOST_DATA_ALIAS."
    err "[0.4.5] Refusing to refresh because user data preservation cannot be proven."
    return 1
  fi
  if [[ "$umbrel_data_source" == "$HOST_DATA_ALIAS" ]]; then
    host_data_alias_ready || { err "[0.4.5] $HOST_DATA_ALIAS is used by umbrel but is not a bind alias to $DATA_DIR."; return 1; }
  fi

  docker_sock_source="$(inspect_umbrel_mount_source /var/run/docker.sock)"
  if [[ "$docker_sock_source" != "/var/run/docker.sock" ]]; then
    err "[0.4.5] Existing umbrel docker.sock mount is ${docker_sock_source:-missing}; refusing to refresh."
    return 1
  fi
}

load_running_app_containers() {
  local container
  STOPPED_APP_CONTAINERS=()
  APP_CONTAINERS_STOPPED=0
  command -v docker >/dev/null 2>&1 || return 0
  while IFS= read -r container; do
    [[ -z "$container" || "$container" == "umbrel" ]] && continue
    is_system_container "$container" && continue
    STOPPED_APP_CONTAINERS+=("$container")
  done < <(docker ps --format '{{.Names}}' 2>/dev/null || true)
}

is_system_container() {
  local container="$1"
  local system_container
  for system_container in "${ALL_KNOWN_SYSTEM_CONTAINERS[@]}"; do
    [[ "$container" == "$system_container" ]] && return 0
  done
  return 1
}

print_running_app_container_hint() {
  command -v docker >/dev/null 2>&1 || return 0
  local container status
  local app_containers=()
  while IFS=' ' read -r container status; do
    [[ -z "$container" || "$container" == "umbrel" ]] && continue
    is_system_container "$container" && continue
    app_containers+=("$container${status:+ $status}")
  done < <(docker ps --format '{{.Names}} {{.Status}}' 2>/dev/null || true)

  if [[ "${#app_containers[@]}" -gt 0 ]]; then
    warn "Umbrel app containers are running and will be stopped gracefully before the system container update:"
    printf '%s\n' "${app_containers[@]}" | sed 's/^/[WARN]   /'
  else
    info "No running Umbrel app container is currently visible alongside the system container."
  fi
}

stop_running_app_containers() {
  if [[ "${#STOPPED_APP_CONTAINERS[@]}" -eq 0 ]]; then
    info "No running Umbrel app containers need to be stopped."
    return 0
  fi

  info "Stopping running Umbrel app containers before the system container refresh (${#STOPPED_APP_CONTAINERS[@]} container(s), timeout ${APP_STOP_TIMEOUT_SECONDS}s)..."
  APP_CONTAINERS_STOPPED=1
  if run_cmd docker stop --timeout "$APP_STOP_TIMEOUT_SECONDS" "${STOPPED_APP_CONTAINERS[@]}"; then
    return 0
  else
    local status=$?
    warn "App container stop failed; attempting to restart any containers that were already stopped."
    start_stopped_app_containers || warn "Failed to restart app containers after stop failure; check Docker manually."
    return "$status"
  fi
}

start_stopped_app_containers() {
  if [[ "$APP_CONTAINERS_STOPPED" -ne 1 || "${#STOPPED_APP_CONTAINERS[@]}" -eq 0 ]]; then
    return 0
  fi

  info "Starting previously running Umbrel app containers again..."
  if [[ "$DRY_RUN" -eq 1 ]]; then
    run_cmd docker start "${STOPPED_APP_CONTAINERS[@]}"
    APP_CONTAINERS_STOPPED=0
    return 0
  fi

  local failed=0
  local container index
  for ((index=${#STOPPED_APP_CONTAINERS[@]} - 1; index >= 0; index--)); do
    container="${STOPPED_APP_CONTAINERS[$index]}"
    if ! docker container inspect "$container" >/dev/null 2>&1; then
      warn "Container $container no longer exists after the Umbrel refresh; skipping direct restart. Umbrel may have recreated it under a new ID."
      continue
    fi
    if ! docker start "$container" >/dev/null; then
      warn "Failed to restart container: $container"
      failed=1
    fi
  done
  APP_CONTAINERS_STOPPED=0
  return "$failed"
}

umbrel_image_id() {
  local image_ref="$1"
  docker image inspect "$image_ref" --format '{{.Id}}' 2>/dev/null || true
}

umbrel_image_ref_resolves_to_image_id() {
  local image_ref="${1:-}"
  local expected_image_id="${2:-}"
  local resolved_image_id=""

  [[ -n "$image_ref" && -n "$expected_image_id" ]] || return 1
  resolved_image_id="$(docker image inspect "$image_ref" --format '{{.Id}}' 2>/dev/null || true)"
  [[ "$resolved_image_id" == "$expected_image_id" ]]
}

run_umbrel_container_with_data_source() {
  local image_ref="$1"
  local data_source="$2"
  run_cmd docker run -d --name umbrel --restart always -p 80:80 -v "$data_source:/data" -v /var/run/docker.sock:/var/run/docker.sock --stop-timeout 60 --pid=host --privileged "$image_ref"
}

run_umbrel_container() {
  run_umbrel_container_with_data_source "$1" "$(umbrel_container_data_source)"
}

rollback_umbrel_container() {
  local old_image_id="$1"
  warn "[0.4.5] New Umbrel container did not stabilize; rolling back to previous image."
  if [[ "$DRY_RUN" -eq 1 ]]; then
    echo "[DRY-RUN] docker rm -f umbrel"
    echo "[DRY-RUN] recreate umbrel with previous image $old_image_id"
    return 0
  fi
  docker rm -f umbrel >/dev/null 2>&1 || true
  if run_umbrel_container "$old_image_id" >/dev/null; then
    warn "[0.4.5] Rollback container started with previous image."
    start_stopped_app_containers || warn "[0.4.5] Failed to restart previously running app containers after rollback."
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

system_container_id() {
  local container="$1"
  docker inspect --format '{{.Id}}' "$container" 2>/dev/null || true
}

system_containers_need_replacement() {
  local container container_id container_state
  for container in "${LEGACY_SYSTEM_CONTAINERS[@]}"; do
    [[ -z "$(system_container_id "$container")" ]] || return 0
  done

  for container in "${CANDIDATE_SYSTEM_CONTAINERS[@]}"; do
    container_id="$(system_container_id "$container")"
    [[ -n "$container_id" ]] || return 0
    container_state="$(docker inspect --format '{{.State.Status}}' "$container" 2>/dev/null || true)"
    [[ "$container_state" == "running" ]] || return 0
  done

  is_expected_tor_proxy_image "$(docker inspect --format '{{.Config.Image}}' umbrel_tor_proxy 2>/dev/null || true)" || return 0
  return 1
}

is_expected_tor_proxy_image() {
  local image_ref="$1"
  [[ "$image_ref" == "$TOR_PROXY_IMAGE" ]] && return 0
  [[ "$image_ref" =~ ^ghcr.io/getumbrel/tor:0\.4\.9\.11@sha256:[0-9a-f]{64}$ ]]
}

candidate_umbrel_container_ready() {
  local expected_image_id="$1"
  local expected_data_source="$2"
  local state image_id image_ref data_source docker_sock_source restart_policy

  state="$(docker inspect --format '{{.State.Status}}' umbrel 2>/dev/null || true)"
  image_id="$(docker inspect --format '{{.Image}}' umbrel 2>/dev/null || true)"
  image_ref="$(docker inspect --format '{{.Config.Image}}' umbrel 2>/dev/null || true)"
  data_source="$(inspect_umbrel_mount_source /data)"
  docker_sock_source="$(inspect_umbrel_mount_source /var/run/docker.sock)"
  restart_policy="$(docker inspect --format '{{.HostConfig.RestartPolicy.Name}}' umbrel 2>/dev/null || true)"

  [[ "$state" == "running" ]] \
    && [[ "$image_id" == "$expected_image_id" ]] \
    && umbrel_image_ref_resolves_to_image_id "$image_ref" "$expected_image_id" \
    && [[ "$data_source" == "$expected_data_source" ]] \
    && [[ "$docker_sock_source" == "/var/run/docker.sock" ]] \
    && [[ "$restart_policy" == "always" ]]
}

candidate_system_containers_ready() {
  local old_auth_id="$1"
  local old_tor_proxy_id="$2"
  local auth_id tor_proxy_id auth_state tor_proxy_state tor_proxy_image

  auth_id="$(system_container_id umbrel_auth)"
  tor_proxy_id="$(system_container_id umbrel_tor_proxy)"
  auth_state="$(docker inspect --format '{{.State.Status}}' umbrel_auth 2>/dev/null || true)"
  tor_proxy_state="$(docker inspect --format '{{.State.Status}}' umbrel_tor_proxy 2>/dev/null || true)"
  tor_proxy_image="$(docker inspect --format '{{.Config.Image}}' umbrel_tor_proxy 2>/dev/null || true)"

  [[ -n "$auth_id" && -n "$tor_proxy_id" ]] \
    && [[ "$auth_state" == "running" && "$tor_proxy_state" == "running" ]] \
    && [[ -z "$old_auth_id" || "$auth_id" != "$old_auth_id" ]] \
    && [[ -z "$old_tor_proxy_id" || "$tor_proxy_id" != "$old_tor_proxy_id" ]] \
    && is_expected_tor_proxy_image "$tor_proxy_image"
}

report_candidate_system_container_diagnostics() {
  local auth_id tor_proxy_id auth_state tor_proxy_state tor_proxy_image
  auth_id="$(system_container_id umbrel_auth)"
  tor_proxy_id="$(system_container_id umbrel_tor_proxy)"
  auth_state="$(docker inspect --format '{{.State.Status}}' umbrel_auth 2>/dev/null || true)"
  tor_proxy_state="$(docker inspect --format '{{.State.Status}}' umbrel_tor_proxy 2>/dev/null || true)"
  tor_proxy_image="$(docker inspect --format '{{.Config.Image}}' umbrel_tor_proxy 2>/dev/null || true)"
  err "Candidate system-container diagnostics: umbrel_auth id=${auth_id:-missing} state=${auth_state:-missing}; umbrel_tor_proxy id=${tor_proxy_id:-missing} state=${tor_proxy_state:-missing} image=${tor_proxy_image:-missing}."
}

wait_for_umbrel_candidate_pre_health() {
  local expected_image_id="$1"
  local expected_data_source="$2"
  local old_auth_id="$3"
  local old_tor_proxy_id="$4"
  local attempt

  for ((attempt = 1; attempt <= CANDIDATE_READINESS_ATTEMPTS; attempt++)); do
    if candidate_umbrel_container_ready "$expected_image_id" "$expected_data_source" \
      && candidate_system_containers_ready "$old_auth_id" "$old_tor_proxy_id"; then
      return 0
    fi
    if [[ "$attempt" -lt "$CANDIDATE_READINESS_ATTEMPTS" ]]; then
      sleep "$CANDIDATE_RETRY_DELAY_SECONDS"
    fi
  done

  err "Umbrel candidate pre-health did not converge after $CANDIDATE_READINESS_ATTEMPTS attempts."
  report_candidate_system_container_diagnostics
  return 1
}

postcheck_system_containers_ready() {
  if [[ "$UMBREL_TRANSACTION_MUTATED" -eq 1 ]]; then
    candidate_system_containers_ready "$UMBREL_TRANSACTION_OLD_AUTH_ID" "$UMBREL_TRANSACTION_OLD_TOR_PROXY_ID"
    return
  fi

  if system_containers_need_replacement; then
    return 1
  fi
  return 0
}

wait_for_postcheck_system_containers() {
  local attempt

  for ((attempt = 1; attempt <= CANDIDATE_READINESS_ATTEMPTS; attempt++)); do
    postcheck_system_containers_ready && return 0
    if [[ "$attempt" -lt "$CANDIDATE_READINESS_ATTEMPTS" ]]; then
      sleep "$CANDIDATE_RETRY_DELAY_SECONDS"
    fi
  done
  return 1
}

replace_system_containers() {
  local container container_id
  for container in "${ALL_KNOWN_SYSTEM_CONTAINERS[@]}"; do
    container_id="$(system_container_id "$container")"
    [[ -n "$container_id" ]] || continue
    docker stop "$container" >/dev/null || return 1
    docker rm "$container" >/dev/null || return 1
  done
}

reset_umbrel_transaction() {
  UMBREL_TRANSACTION_ACTIVE=0
  UMBREL_TRANSACTION_MUTATED=0
  UMBREL_TRANSACTION_OLD_IMAGE_ID=""
  UMBREL_TRANSACTION_OLD_IMAGE_REF=""
  UMBREL_TRANSACTION_OLD_AUTH_ID=""
  UMBREL_TRANSACTION_OLD_AUTH_IMAGE=""
  UMBREL_TRANSACTION_OLD_AUTH_STATE=""
  UMBREL_TRANSACTION_OLD_TOR_PROXY_ID=""
  UMBREL_TRANSACTION_OLD_TOR_PROXY_IMAGE=""
  UMBREL_TRANSACTION_OLD_TOR_PROXY_STATE=""
  UMBREL_TRANSACTION_DATA_SOURCE=""
  UMBREL_TRANSACTION_APP_CONTAINERS=()
}

capture_umbrel_transaction_context() {
  reset_umbrel_transaction
  UMBREL_TRANSACTION_OLD_IMAGE_ID="$(docker inspect umbrel --format '{{.Image}}' 2>/dev/null || true)"
  UMBREL_TRANSACTION_OLD_IMAGE_REF="$(docker inspect umbrel --format '{{.Config.Image}}' 2>/dev/null || true)"
  UMBREL_TRANSACTION_OLD_AUTH_ID="$(system_container_id auth)"
  UMBREL_TRANSACTION_OLD_AUTH_IMAGE="$(docker inspect auth --format '{{.Config.Image}}' 2>/dev/null || true)"
  UMBREL_TRANSACTION_OLD_AUTH_STATE="$(docker inspect auth --format '{{.State.Status}}' 2>/dev/null || true)"
  UMBREL_TRANSACTION_OLD_TOR_PROXY_ID="$(system_container_id tor_proxy)"
  UMBREL_TRANSACTION_OLD_TOR_PROXY_IMAGE="$(docker inspect tor_proxy --format '{{.Config.Image}}' 2>/dev/null || true)"
  UMBREL_TRANSACTION_OLD_TOR_PROXY_STATE="$(docker inspect tor_proxy --format '{{.State.Status}}' 2>/dev/null || true)"
  UMBREL_TRANSACTION_DATA_SOURCE="$(umbrel_container_data_source)"
  [[ -n "$UMBREL_TRANSACTION_OLD_IMAGE_ID" && -n "$UMBREL_TRANSACTION_OLD_IMAGE_REF" && -n "$UMBREL_TRANSACTION_DATA_SOURCE" ]] || {
    err "Could not capture the current Umbrel transaction context."
    return 1
  }
  load_running_app_containers
  UMBREL_TRANSACTION_APP_CONTAINERS=("${STOPPED_APP_CONTAINERS[@]}")
}

umbrel_transaction_context_is_valid() {
  [[ -n "$UMBREL_TRANSACTION_OLD_IMAGE_ID" && -n "$UMBREL_TRANSACTION_OLD_IMAGE_REF" && -n "$UMBREL_TRANSACTION_DATA_SOURCE" ]] || return 1
  if [[ -n "$UMBREL_TRANSACTION_OLD_AUTH_ID" ]]; then
    [[ -n "$UMBREL_TRANSACTION_OLD_AUTH_IMAGE" && -n "$UMBREL_TRANSACTION_OLD_AUTH_STATE" ]] || return 1
  fi
  if [[ -n "$UMBREL_TRANSACTION_OLD_TOR_PROXY_ID" ]]; then
    [[ -n "$UMBREL_TRANSACTION_OLD_TOR_PROXY_IMAGE" && -n "$UMBREL_TRANSACTION_OLD_TOR_PROXY_STATE" ]] || return 1
  fi
}

old_umbrel_stack_ready() {
  local state image_id data_source docker_sock_source restart_policy auth_state tor_proxy_state
  state="$(docker inspect umbrel --format '{{.State.Status}}' 2>/dev/null || true)"
  image_id="$(docker inspect umbrel --format '{{.Image}}' 2>/dev/null || true)"
  data_source="$(inspect_umbrel_mount_source /data)"
  docker_sock_source="$(inspect_umbrel_mount_source /var/run/docker.sock)"
  restart_policy="$(docker inspect umbrel --format '{{.HostConfig.RestartPolicy.Name}}' 2>/dev/null || true)"
  auth_state="$(docker inspect auth --format '{{.State.Status}}' 2>/dev/null || true)"
  tor_proxy_state="$(docker inspect tor_proxy --format '{{.State.Status}}' 2>/dev/null || true)"

  [[ "$state" == "running" ]] \
    && [[ "$image_id" == "$UMBREL_TRANSACTION_OLD_IMAGE_ID" ]] \
    && [[ "$data_source" == "$UMBREL_TRANSACTION_DATA_SOURCE" ]] \
    && [[ "$docker_sock_source" == "/var/run/docker.sock" ]] \
    && [[ "$restart_policy" == "always" ]] \
    && [[ "$auth_state" == "running" && "$tor_proxy_state" == "running" ]]
}

wait_for_old_umbrel_stack() {
  local attempt
  for ((attempt = 1; attempt <= CANDIDATE_READINESS_ATTEMPTS; attempt++)); do
    old_umbrel_stack_ready && return 0
    if [[ "$attempt" -lt "$CANDIDATE_READINESS_ATTEMPTS" ]]; then
      sleep "$CANDIDATE_RETRY_DELAY_SECONDS"
    fi
  done
  return 1
}

rollback_umbrel_transaction() {
  local container
  [[ "$UMBREL_TRANSACTION_ACTIVE" -eq 1 && "$UMBREL_TRANSACTION_MUTATED" -eq 1 ]] || return 0

  warn "Rolling back the Umbrel candidate to the previous top-level image."
  for container in umbrel "${ALL_KNOWN_SYSTEM_CONTAINERS[@]}"; do
    docker rm -f "$container" >/dev/null 2>&1 || true
  done

  if ! run_umbrel_container_with_data_source "$UMBREL_TRANSACTION_OLD_IMAGE_ID" "$UMBREL_TRANSACTION_DATA_SOURCE" >/dev/null; then
    err "Rollback failed while starting the previous Umbrel image."
    return 1
  fi
  if ! wait_for_old_umbrel_stack; then
    err "Rollback failed because the previous Umbrel system stack did not become ready."
    return 1
  fi
  if ! start_stopped_app_containers; then
    err "Rollback failed while restoring previously running ordinary apps."
    return 1
  fi
  return 0
}

fail_umbrel_transaction() {
  local failure_message="$1"
  UMBREL_TRANSACTION_FAILURE_MESSAGE="$failure_message"
  if [[ "$UMBREL_TRANSACTION_MUTATED" -eq 1 ]] && ! rollback_umbrel_transaction; then
    UMBREL_TRANSACTION_FAILURE_MESSAGE="$failure_message; rollback failed"
    reset_umbrel_transaction
    return 1
  fi
  reset_umbrel_transaction
  return 1
}

begin_umbrel_candidate_transaction() {
  local force_replacement="${1:-0}"
  assert_fullnode_data_mount_safe || return 1
  capture_umbrel_transaction_context || return 1
  umbrel_transaction_context_is_valid || { err "Captured Umbrel transaction context is incomplete."; return 1; }

  if [[ "$DRY_RUN" -eq 1 ]]; then
    echo "[DRY-RUN] docker pull $UMBREL_IMAGE"
    echo "[DRY-RUN] stop ordinary apps, replace system containers, and run the candidate only after the image resolves"
    return 0
  fi

  if ! docker pull "$UMBREL_IMAGE" >/dev/null; then
    err "Could not pull candidate image $UMBREL_IMAGE; no containers were stopped."
    return 1
  fi
  UMBREL_TRANSACTION_TARGET_IMAGE_ID="$(umbrel_image_id "$UMBREL_IMAGE")"
  [[ -n "$UMBREL_TRANSACTION_TARGET_IMAGE_ID" ]] || { err "Could not resolve the pulled candidate image ID."; return 1; }
  UMBREL_TRANSACTION_ACTIVE=1

  if [[ "$force_replacement" -ne 1 && "$UMBREL_TRANSACTION_OLD_IMAGE_ID" == "$UMBREL_TRANSACTION_TARGET_IMAGE_ID" ]] && ! system_containers_need_replacement; then
    info "Umbrel candidate image and system containers are already current."
    return 0
  fi

  UMBREL_TRANSACTION_MUTATED=1
  STOPPED_APP_CONTAINERS=("${UMBREL_TRANSACTION_APP_CONTAINERS[@]}")
  stop_running_app_containers || return 1
  replace_system_containers || return 1
  docker stop umbrel >/dev/null || return 1
  docker rm umbrel >/dev/null || return 1
  run_umbrel_container_with_data_source "$UMBREL_IMAGE" "$UMBREL_TRANSACTION_DATA_SOURCE" >/dev/null || return 1
  wait_for_umbrel_candidate_pre_health "$UMBREL_TRANSACTION_TARGET_IMAGE_ID" "$UMBREL_TRANSACTION_DATA_SOURCE" "$UMBREL_TRANSACTION_OLD_AUTH_ID" "$UMBREL_TRANSACTION_OLD_TOR_PROXY_ID"
}

wait_for_umbrel_http() {
  local attempt
  command -v curl >/dev/null 2>&1 || { err "curl is required for Umbrel HTTP readiness verification."; return 1; }
  for ((attempt = 1; attempt <= CANDIDATE_READINESS_ATTEMPTS; attempt++)); do
    curl -fsS --max-time 10 http://127.0.0.1/ >/dev/null 2>&1 && return 0
    if [[ "$attempt" -lt "$CANDIDATE_READINESS_ATTEMPTS" ]]; then
      sleep "$CANDIDATE_RETRY_DELAY_SECONDS"
    fi
  done
  err "Umbrel HTTP did not become ready after $CANDIDATE_READINESS_ATTEMPTS attempts."
  return 1
}

complete_umbrel_transaction() {
  if ! start_stopped_app_containers; then
    fail_umbrel_transaction "ordinary app restart failed after candidate postcheck"
    return 1
  fi
  reset_umbrel_transaction
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

patch_umbrel_shutdown_ui() {
  docker exec -i umbrel python3 - <<'PY_INNER'
import hashlib
import json
import os
import re
import sys
from pathlib import Path

ROOT = Path(os.environ.get('M1S_TEST_UMBREL_UI_ROOT', '/opt/umbreld/ui')).resolve()
INDEX = ROOT / 'index.html'
SOURCE_ERROR_30 = 'he==="shutting-down"&&!v&&(ce.isError||ce.failureCount>0)&&(b(!0),setTimeout(()=>S(!0),30*Kh))'
PUBLIC_STATUS_30 = 'he==="shutting-down"&&!v&&(b(!0),setTimeout(()=>S(!0),30*Kh))'
CANONICAL_STATUS_75 = 'he==="shutting-down"&&!v&&(b(!0),setTimeout(()=>S(!0),75*Kh))'
SCRIPT_TAG_RE = re.compile(r'<script\b(?P<attrs>[^>]*)>', re.IGNORECASE)
LINK_TAG_RE = re.compile(r'<link\b(?P<attrs>[^>]*)>', re.IGNORECASE)
IMPORT_MAP_TAG_RE = re.compile(r'<script\b(?P<attrs>[^>]*)>(?P<body>.*?)</script\s*>', re.IGNORECASE | re.DOTALL)
ATTRIBUTE_RE = re.compile(
    r'''(?:^|\s+)(?P<name>[\w:-]+)(?:\s*=\s*(?:"(?P<double>[^"]*)"|'(?P<single>[^']*)'))?''',
    re.IGNORECASE,
)
EXECUTABLE_SCRIPT_TYPES = {'', 'module', 'text/javascript', 'application/javascript'}
ASSET_REF_RE = re.compile(r'^/assets/[^"\']+\.js$')
HASHED_NAME_RE = re.compile(r'^(?P<stem>.+)\.m1s-(?P<digest>[0-9a-f]{12})\.js$')


def fail(message):
    print(f'Umbrel shutdown UI patch failed: {message}', file=sys.stderr)
    raise SystemExit(1)


def contained(path):
    return path == ROOT or ROOT in path.parents


def parse_attributes(raw_attributes):
    attributes = {}
    attribute_spans = {}
    for attribute in ATTRIBUTE_RE.finditer(raw_attributes):
        name = attribute.group('name').lower()
        if name in attributes:
            fail('script tag has duplicate attributes')
        if attribute.group('double') is not None:
            attributes[name] = attribute.group('double')
            attribute_spans[name] = (attribute.start('double'), attribute.end('double'))
        elif attribute.group('single') is not None:
            attributes[name] = attribute.group('single')
            attribute_spans[name] = (attribute.start('single'), attribute.end('single'))
        else:
            attributes[name] = ''
    return attributes, attribute_spans


def has_managed_import_map_attribute(attributes):
    return 'data-m1s-shutdown-ui' in attributes


def has_modulepreload_rel(attributes):
    return 'modulepreload' in attributes.get('rel', '').lower().split()


def executable_script_candidates(index_text):
    candidates = []
    for script_tag in SCRIPT_TAG_RE.finditer(index_text):
        attributes, attribute_spans = parse_attributes(script_tag.group('attrs'))
        script_type = attributes.get('type', '').strip().lower()
        ref = attributes.get('src')
        if ref is not None and script_type in EXECUTABLE_SCRIPT_TYPES:
            candidates.append((
                ref,
                (
                    script_tag.start('attrs') + attribute_spans['src'][0],
                    script_tag.start('attrs') + attribute_spans['src'][1],
                ),
                script_tag.start(),
            ))
    return candidates


def module_graph_trigger_starts(index_text, executable_candidates):
    starts = {candidate[2] for candidate in executable_candidates}
    for script_tag in SCRIPT_TAG_RE.finditer(index_text):
        attributes, _ = parse_attributes(script_tag.group('attrs'))
        if attributes.get('type', '').strip().lower() == 'module':
            starts.add(script_tag.start())
    for link_tag in LINK_TAG_RE.finditer(index_text):
        attributes, _ = parse_attributes(link_tag.group('attrs'))
        if has_modulepreload_rel(attributes):
            starts.add(link_tag.start())
    return sorted(starts)


def import_map_candidates(index_text):
    import_map_open_count = 0
    managed_open_count = 0
    for script_tag in SCRIPT_TAG_RE.finditer(index_text):
        attributes, _ = parse_attributes(script_tag.group('attrs'))
        if has_managed_import_map_attribute(attributes):
            managed_open_count += 1
        if attributes.get('type', '').strip().lower() == 'importmap':
            import_map_open_count += 1
            if 'src' in attributes:
                fail('import map must be inline')

    candidates = []
    for import_map_tag in IMPORT_MAP_TAG_RE.finditer(index_text):
        attributes, _ = parse_attributes(import_map_tag.group('attrs'))
        if attributes.get('type', '').strip().lower() != 'importmap':
            continue
        try:
            data = json.loads(import_map_tag.group('body'))
        except json.JSONDecodeError:
            fail('import map JSON is malformed')
        if not isinstance(data, dict) or not isinstance(data.get('imports', {}), dict):
            fail('import map must contain an object imports field')
        scopes = data.get('scopes', {})
        if not isinstance(scopes, dict):
            fail('import map scopes field must be an object')
        if any(not isinstance(value, str) for value in data.get('imports', {}).values()):
            fail('import map imports must map to strings')
        if any(not isinstance(scope, dict) for scope in scopes.values()):
            fail('import map scopes must map to objects')
        candidates.append({
            'data': data,
            'managed': has_managed_import_map_attribute(attributes),
            'start': import_map_tag.start(),
        })
    if import_map_open_count != len(candidates) or managed_open_count != sum(item['managed'] for item in candidates):
        fail('import map tag is malformed')
    return candidates


def import_map_references(import_map, original_ref):
    if original_ref in import_map['data'].get('imports', {}):
        return True
    return any(original_ref in scope for scope in import_map['data'].get('scopes', {}).values())


def validate_unmanaged_import_maps(import_maps, original_ref):
    if any(not item['managed'] and import_map_references(item, original_ref) for item in import_maps):
        fail('unmanaged import map conflicts with the original shutdown UI entry')


def canonical_import_map_present(import_maps, original_ref, target_ref, trigger_starts):
    validate_unmanaged_import_maps(import_maps, original_ref)
    managed_maps = [item for item in import_maps if item['managed']]
    if len(managed_maps) > 1:
        fail('expected exactly one managed import map')
    if not managed_maps:
        return False
    managed_map = managed_maps[0]
    if any(managed_map['start'] >= trigger_start for trigger_start in trigger_starts):
        fail('managed import map must precede every module graph trigger')
    if managed_map['data'] != {'imports': {original_ref: target_ref}}:
        fail('managed import map does not exactly map the original entry to the generated entry')
    return True


def managed_import_map_tag(original_ref, target_ref):
    payload = json.dumps({'imports': {original_ref: target_ref}}, separators=(',', ':'))
    return f'<script type="importmap" data-m1s-shutdown-ui>{payload}</script>\n'


def fsync_parent(path):
    try:
        fd = os.open(path.parent, os.O_RDONLY)
        try:
            os.fsync(fd)
        finally:
            os.close(fd)
    except OSError:
        pass


def atomic_write(path, data):
    tmp = path.with_name(f'.{path.name}.tmp-{os.getpid()}')
    try:
        with tmp.open('wb') as handle:
            handle.write(data)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(tmp, path)
        fsync_parent(path)
    finally:
        try:
            tmp.unlink()
        except FileNotFoundError:
            pass


def resolve_index_asset():
    if not INDEX.is_file():
        fail('index.html is missing')
    index_text = INDEX.read_text(encoding='utf-8')
    candidates = executable_script_candidates(index_text)
    if len(candidates) != 1:
        fail(f'expected exactly one executable index script reference, found {len(candidates)}')
    ref, ref_span, executable_start = candidates[0]
    trigger_starts = module_graph_trigger_starts(index_text, candidates)
    if ASSET_REF_RE.fullmatch(ref) is None or '..' in Path(ref).parts or '?' in ref or '#' in ref:
        fail('index executable script reference is not a safe path')
    asset_path = (ROOT / ref.lstrip('/')).resolve()
    if not contained(asset_path) or asset_path.parent != (ROOT / 'assets').resolve():
        fail('index executable script reference escapes the UI asset directory')
    if not asset_path.is_file():
        fail('referenced executable JavaScript asset is missing')
    return index_text, ref, ref_span, trigger_starts, asset_path


def base_stem_for(asset_path):
    hashed_match = HASHED_NAME_RE.fullmatch(asset_path.name)
    if hashed_match:
        return hashed_match.group('stem')
    return asset_path.stem


def validate_no_stale_generated(asset_path, base_stem, canonical_indexed):
    generated = sorted(asset_path.parent.glob(f'{base_stem}.m1s-*.js'))
    allowed = [asset_path] if canonical_indexed else []
    if [path.resolve() for path in generated] != [path.resolve() for path in allowed]:
        fail('stale or ambiguous generated shutdown UI asset is present')


def validate_canonical_filename(asset_path, asset_bytes):
    hashed_match = HASHED_NAME_RE.fullmatch(asset_path.name)
    if not hashed_match:
        fail('canonical shutdown UI asset is not content-hashed')
    digest = hashlib.sha256(asset_bytes).hexdigest()[:12]
    if hashed_match.group('digest') != digest:
        fail('shutdown UI asset filename hash does not match its content')


index_text, ref, ref_span, trigger_starts, asset_path = resolve_index_asset()
asset_bytes = asset_path.read_bytes()
asset_text = asset_bytes.decode('utf-8')
counts = {
    'upstream-error-30': asset_text.count(SOURCE_ERROR_30),
    'public-status-30': asset_text.count(PUBLIC_STATUS_30),
    'canonical-status-75': asset_text.count(CANONICAL_STATUS_75),
}
if sum(counts.values()) != 1:
    fail(f'expected exactly one known shutdown UI branch, found {counts}')
base_stem = base_stem_for(asset_path)
if counts['canonical-status-75'] == 1:
    validate_no_stale_generated(asset_path, base_stem, True)
    validate_canonical_filename(asset_path, asset_bytes)
    original_ref = f'/assets/{base_stem}.js'
    original_path = asset_path.with_name(f'{base_stem}.js')
    if not original_path.is_file():
        fail('original immutable shutdown UI asset is missing')
    if canonical_import_map_present(import_map_candidates(index_text), original_ref, ref, trigger_starts):
        raise SystemExit(0)
    insertion_start = min(trigger_starts)
    atomic_write(INDEX, (index_text[:insertion_start] + managed_import_map_tag(original_ref, ref) + index_text[insertion_start:]).encode('utf-8'))
    raise SystemExit(0)

validate_no_stale_generated(asset_path, base_stem, False)
import_maps = import_map_candidates(index_text)
if any(item['managed'] for item in import_maps):
    fail('source shutdown UI entry cannot already have a managed import map')
validate_unmanaged_import_maps(import_maps, ref)
patched_text = asset_text
for source in (SOURCE_ERROR_30, PUBLIC_STATUS_30):
    patched_text = patched_text.replace(source, CANONICAL_STATUS_75, 1)
patched_bytes = patched_text.encode('utf-8')
digest = hashlib.sha256(patched_bytes).hexdigest()[:12]
new_name = f'{base_stem}.m1s-{digest}.js'
new_ref = f'/assets/{new_name}'
new_path = asset_path.with_name(new_name)
ref_start, ref_end = ref_span
if index_text[ref_start:ref_end] != ref:
    fail('selected executable script reference does not match its index span')
rewritten_index_text = index_text[:ref_start] + new_ref + index_text[ref_end:]
insertion_start = min(trigger_starts)
new_index_text = rewritten_index_text[:insertion_start] + managed_import_map_tag(ref, new_ref) + rewritten_index_text[insertion_start:]
atomic_write(new_path, patched_bytes)
try:
    atomic_write(INDEX, new_index_text.encode('utf-8'))
except BaseException:
    try:
        new_path.unlink()
        fsync_parent(new_path)
    except OSError:
        pass
    raise
PY_INNER
}

verify_umbrel_shutdown_ui() {
  docker exec -i umbrel python3 - <<'PY_INNER'
import hashlib
import json
import os
import re
import sys
from pathlib import Path

ROOT = Path(os.environ.get('M1S_TEST_UMBREL_UI_ROOT', '/opt/umbreld/ui')).resolve()
INDEX = ROOT / 'index.html'
SOURCE_ERROR_30 = 'he==="shutting-down"&&!v&&(ce.isError||ce.failureCount>0)&&(b(!0),setTimeout(()=>S(!0),30*Kh))'
PUBLIC_STATUS_30 = 'he==="shutting-down"&&!v&&(b(!0),setTimeout(()=>S(!0),30*Kh))'
CANONICAL_STATUS_75 = 'he==="shutting-down"&&!v&&(b(!0),setTimeout(()=>S(!0),75*Kh))'
SCRIPT_TAG_RE = re.compile(r'<script\b(?P<attrs>[^>]*)>', re.IGNORECASE)
LINK_TAG_RE = re.compile(r'<link\b(?P<attrs>[^>]*)>', re.IGNORECASE)
IMPORT_MAP_TAG_RE = re.compile(r'<script\b(?P<attrs>[^>]*)>(?P<body>.*?)</script\s*>', re.IGNORECASE | re.DOTALL)
ATTRIBUTE_RE = re.compile(
    r'''(?:^|\s+)(?P<name>[\w:-]+)(?:\s*=\s*(?:"(?P<double>[^"]*)"|'(?P<single>[^']*)'))?''',
    re.IGNORECASE,
)
EXECUTABLE_SCRIPT_TYPES = {'', 'module', 'text/javascript', 'application/javascript'}
ASSET_REF_RE = re.compile(r'^/assets/[^"\']+\.js$')
HASHED_NAME_RE = re.compile(r'^(?P<stem>.+)\.m1s-(?P<digest>[0-9a-f]{12})\.js$')


def fail(message):
    print(f'Umbrel shutdown UI verification failed: {message}', file=sys.stderr)
    raise SystemExit(1)


def contained(path):
    return path == ROOT or ROOT in path.parents


def parse_attributes(raw_attributes):
    attributes = {}
    for attribute in ATTRIBUTE_RE.finditer(raw_attributes):
        name = attribute.group('name').lower()
        if name in attributes:
            fail('script tag has duplicate attributes')
        if attribute.group('double') is not None:
            attributes[name] = attribute.group('double')
        elif attribute.group('single') is not None:
            attributes[name] = attribute.group('single')
        else:
            attributes[name] = ''
    return attributes


def has_managed_import_map_attribute(attributes):
    return 'data-m1s-shutdown-ui' in attributes


def has_modulepreload_rel(attributes):
    return 'modulepreload' in attributes.get('rel', '').lower().split()


def executable_script_candidates(index_text):
    candidates = []
    for script_tag in SCRIPT_TAG_RE.finditer(index_text):
        attributes = parse_attributes(script_tag.group('attrs'))
        script_type = attributes.get('type', '').strip().lower()
        ref = attributes.get('src')
        if ref is not None and script_type in EXECUTABLE_SCRIPT_TYPES:
            candidates.append((ref, script_tag.start()))
    return candidates


def module_graph_trigger_starts(index_text, executable_candidates):
    starts = {candidate[1] for candidate in executable_candidates}
    for script_tag in SCRIPT_TAG_RE.finditer(index_text):
        attributes = parse_attributes(script_tag.group('attrs'))
        if attributes.get('type', '').strip().lower() == 'module':
            starts.add(script_tag.start())
    for link_tag in LINK_TAG_RE.finditer(index_text):
        attributes = parse_attributes(link_tag.group('attrs'))
        if has_modulepreload_rel(attributes):
            starts.add(link_tag.start())
    return sorted(starts)


def import_map_candidates(index_text):
    import_map_open_count = 0
    managed_open_count = 0
    for script_tag in SCRIPT_TAG_RE.finditer(index_text):
        attributes = parse_attributes(script_tag.group('attrs'))
        if has_managed_import_map_attribute(attributes):
            managed_open_count += 1
        if attributes.get('type', '').strip().lower() == 'importmap':
            import_map_open_count += 1
            if 'src' in attributes:
                fail('import map must be inline')
    candidates = []
    for import_map_tag in IMPORT_MAP_TAG_RE.finditer(index_text):
        attributes = parse_attributes(import_map_tag.group('attrs'))
        if attributes.get('type', '').strip().lower() != 'importmap':
            continue
        try:
            data = json.loads(import_map_tag.group('body'))
        except json.JSONDecodeError:
            fail('import map JSON is malformed')
        if not isinstance(data, dict) or not isinstance(data.get('imports', {}), dict):
            fail('import map must contain an object imports field')
        scopes = data.get('scopes', {})
        if not isinstance(scopes, dict) or any(not isinstance(scope, dict) for scope in scopes.values()):
            fail('import map scopes field must map to objects')
        if any(not isinstance(value, str) for value in data.get('imports', {}).values()):
            fail('import map imports must map to strings')
        candidates.append({
            'data': data,
            'managed': has_managed_import_map_attribute(attributes),
            'start': import_map_tag.start(),
        })
    if import_map_open_count != len(candidates) or managed_open_count != sum(item['managed'] for item in candidates):
        fail('import map tag is malformed')
    return candidates


def import_map_references(import_map, original_ref):
    if original_ref in import_map['data'].get('imports', {}):
        return True
    return any(original_ref in scope for scope in import_map['data'].get('scopes', {}).values())


if not INDEX.is_file():
    fail('index.html is missing')
index_text = INDEX.read_text(encoding='utf-8')
candidates = executable_script_candidates(index_text)
if len(candidates) != 1:
    fail(f'expected exactly one executable index script reference, found {len(candidates)}')
ref, executable_start = candidates[0]
trigger_starts = module_graph_trigger_starts(index_text, candidates)
if ASSET_REF_RE.fullmatch(ref) is None or '..' in Path(ref).parts or '?' in ref or '#' in ref:
    fail('index executable script reference is not a safe path')
asset_path = (ROOT / ref.lstrip('/')).resolve()
if not contained(asset_path) or asset_path.parent != (ROOT / 'assets').resolve():
    fail('index executable script reference escapes the UI asset directory')
if not asset_path.is_file():
    fail('referenced executable JavaScript asset is missing')
asset_bytes = asset_path.read_bytes()
asset_text = asset_bytes.decode('utf-8')
source_count = asset_text.count(SOURCE_ERROR_30) + asset_text.count(PUBLIC_STATUS_30)
canonical_count = asset_text.count(CANONICAL_STATUS_75)
if source_count != 0 or canonical_count != 1:
    fail(f'expected one canonical 75s branch and no source/30s branches, found source={source_count} canonical={canonical_count}')
hashed_match = HASHED_NAME_RE.fullmatch(asset_path.name)
if not hashed_match:
    fail('canonical shutdown UI asset is not content-hashed')
digest = hashlib.sha256(asset_bytes).hexdigest()[:12]
if hashed_match.group('digest') != digest:
    fail('shutdown UI asset filename hash does not match its content')
generated = sorted(asset_path.parent.glob(f"{hashed_match.group('stem')}.m1s-*.js"))
if [path.resolve() for path in generated] != [asset_path]:
    fail('stale or ambiguous generated shutdown UI asset is present')
original_ref = f"/assets/{hashed_match.group('stem')}.js"
original_path = (ROOT / original_ref.lstrip('/')).resolve()
if not contained(original_path) or original_path.parent != (ROOT / 'assets').resolve() or not original_path.is_file():
    fail('original immutable shutdown UI asset is missing')
import_maps = import_map_candidates(index_text)
if any(not item['managed'] and import_map_references(item, original_ref) for item in import_maps):
    fail('unmanaged import map conflicts with the original shutdown UI entry')
managed_maps = [item for item in import_maps if item['managed']]
if len(managed_maps) != 1:
    fail('expected exactly one managed import map')
if any(managed_maps[0]['start'] >= trigger_start for trigger_start in trigger_starts):
    fail('managed import map must precede every module graph trigger')
if managed_maps[0]['data'] != {'imports': {original_ref: ref}}:
    fail('managed import map does not exactly map the original entry to the generated entry')
PY_INNER
}


install_umbrel_safe_shutdown() {
  info "Installing safe-to-unplug Umbrel shutdown behavior"

  if [[ "$DRY_RUN" -eq 1 ]]; then
    echo "[DRY-RUN] create $SAFE_SHUTDOWN_SERVICE"
    echo "[DRY-RUN] patch Umbrel shutdown() to disable Docker auto-restart and delay stopping the top-level umbrel container for the completion screen"
    echo "[DRY-RUN] patch Umbrel 1.7.4 shutdown UI timer to start from shutting-down state"
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
  patch_umbrel_shutdown_ui || { err "Umbrel shutdown UI timer patch could not be written"; return 1; }
  verify_umbrel_shutdown_ui || { err "Umbrel shutdown UI timer patch is missing"; return 1; }

  systemctl daemon-reload
  systemctl enable m1s-umbrel-autostart.service >/dev/null

  # Restart once so the running umbreld process loads the patched shutdown()
  # implementation. Existing apps are preserved and auto-start again normally.
  docker update --restart=always umbrel >/dev/null
  docker restart --time 60 umbrel >/dev/null
  wait_for_umbrel_container || { err "Umbrel did not restart after safe shutdown container patch."; return 1; }

  if ! verify_umbrel_shutdown_source || ! verify_umbrel_shutdown_ui; then
    warn "Umbrel shutdown patch was not present after restart; retrying patch and restart once."
    patch_umbrel_shutdown_source
    verify_umbrel_shutdown_source || { err "Umbrel shutdown() safe-stop container patch is missing after retry write"; return 1; }
    patch_umbrel_shutdown_ui || { err "Umbrel shutdown UI timer patch is missing after retry write"; return 1; }
    verify_umbrel_shutdown_ui || { err "Umbrel shutdown UI timer patch is missing after retry write"; return 1; }
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
  verify_umbrel_shutdown_ui || { err "Umbrel shutdown UI timer patch is missing"; return 1; }
  local restart_policy
  restart_policy="$(docker inspect umbrel --format '{{.HostConfig.RestartPolicy.Name}}' 2>/dev/null || true)"
  [[ "$restart_policy" == "always" ]] || { err "umbrel restart policy should be always during normal operation, got ${restart_policy:-unknown}"; return 1; }
}

refresh_umbrel_system_container() {
  if ! begin_umbrel_candidate_transaction; then
    fail_umbrel_transaction "legacy system container refresh failed"
    return 1
  fi
  if ! complete_umbrel_transaction; then
    return 1
  fi
  info "Umbrel system container refresh completed and restored ordinary apps."
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
  local runtime_image="${5:-}"
  local runtime_image_id="${6:-}"
  if [[ "$DRY_RUN" -eq 1 ]]; then
    echo "[DRY-RUN] update $INSTALL_STATE_FILE (action=$action step=${step:-none} version=${version:-unchanged})"
    return 0
  fi

  mkdir -p "$INSTALL_STATE_DIR"
  local ts
  ts="$(date -Is)"
  python3 - "$INSTALL_STATE_FILE" "$action" "$step" "$version" "$message" "$ts" "$SCRIPT_VERSION" "$DATA_DIR" "$UMBREL_IMAGE" "$runtime_image" "$runtime_image_id" <<'PY'
import json, os, sys, tempfile

path, action, step, version, message, ts, script_version, data_dir, target_image, runtime_image, runtime_image_id = sys.argv[1:12]
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
base["updated_at"] = ts
base["updated_by"] = "m1s-update-umbrel.sh"

if action == "started":
    base["in_progress_step"] = step
    base["failed_step"] = None
    base["last_error"] = None
    base["target_image"] = target_image
elif action == "completed":
    if step and step not in steps:
        steps.append(step)
    if version:
        base["last_completed_version"] = version
    base["in_progress_step"] = None
    base["failed_step"] = None
    base["last_error"] = None
    base.pop("last_attempted_image", None)
elif action == "failed":
    base["in_progress_step"] = None
    base["failed_step"] = step
    base["last_error"] = message or "migration step failed"
    base["last_attempted_image"] = target_image
    base.pop("target_image", None)
    if runtime_image and runtime_image_id:
        base["image"] = runtime_image
        base["image_id"] = runtime_image_id
elif action == "finalized":
    if version:
        base["version"] = version
        base["host_version"] = version
    if runtime_image and runtime_image_id:
        base["image"] = runtime_image
        base["image_id"] = runtime_image_id
    base["in_progress_step"] = None
    base["failed_step"] = None
    base["last_error"] = None
    base.pop("target_image", None)
    base.pop("last_attempted_image", None)
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
mark_step_failed() {
  local runtime_image runtime_image_id
  runtime_image="$(docker inspect umbrel --format '{{.Config.Image}}' 2>/dev/null || true)"
  runtime_image_id="$(docker inspect umbrel --format '{{.Image}}' 2>/dev/null || true)"
  update_install_state failed "$1" "" "$2" "$runtime_image" "$runtime_image_id"
}
report_umbrel_runtime_truth_failure() {
  local predicate="$1"
  local observed_state="$2"
  local legacy_refusal="${3:-}"
  if [[ -n "$legacy_refusal" ]]; then
    err "$legacy_refusal Runtime truth diagnostic: predicate=$predicate observed-state=$observed_state"
  else
    err "Runtime truth diagnostic: predicate=$predicate observed-state=$observed_state"
  fi
}

verified_umbrel_runtime_snapshot() {
  local runtime_image runtime_image_id expected_image_id

  runtime_image="$(docker inspect umbrel --format '{{.Config.Image}}' 2>/dev/null || true)"
  runtime_image_id="$(docker inspect umbrel --format '{{.Image}}' 2>/dev/null || true)"
  expected_image_id="$(umbrel_image_id "$UMBREL_IMAGE")"

  [[ -n "$runtime_image" ]] || {
    report_umbrel_runtime_truth_failure "top-level-image-reference" "not-canonical" "Refusing to finalize because the live Umbrel runtime image reference could not be verified."
    return 1
  }
  [[ -n "$expected_image_id" && -n "$runtime_image_id" && "$runtime_image_id" == "$expected_image_id" ]] || {
    report_umbrel_runtime_truth_failure "top-level-image-id" "not-canonical" "Refusing to finalize because the live Umbrel runtime image ID could not be verified."
    return 1
  }
  umbrel_image_ref_resolves_to_image_id "$runtime_image" "$expected_image_id" || {
    report_umbrel_runtime_truth_failure "top-level-image-reference" "not-canonical" "Refusing to finalize because the live Umbrel runtime image reference could not be verified."
    return 1
  }

  VERIFIED_UMBREL_RUNTIME_IMAGE="$UMBREL_IMAGE"
  VERIFIED_UMBREL_RUNTIME_IMAGE_ID="$runtime_image_id"
}

verify_umbrel_runtime_truth() {
  local runtime_snapshot_verified="${1:-0}"
  local data_source expected_image_id runtime_state restart_policy docker_sock_source

  if [[ "$runtime_snapshot_verified" -ne 1 ]]; then
    verified_umbrel_runtime_snapshot || return 1
  fi

  if ! assert_fullnode_data_mount_safe >/dev/null 2>&1; then
    docker_sock_source="$(inspect_umbrel_mount_source /var/run/docker.sock)"
    if [[ "$docker_sock_source" != "/var/run/docker.sock" ]]; then
      report_umbrel_runtime_truth_failure "docker-socket-mount" "not-canonical"
    else
      report_umbrel_runtime_truth_failure "data-identity-binding" "not-proven"
    fi
    return 1
  fi

  data_source="$(inspect_umbrel_mount_source /data)"
  expected_image_id="$(umbrel_image_id "$UMBREL_IMAGE")"
  if ! candidate_umbrel_container_ready "$expected_image_id" "$data_source"; then
    runtime_state="$(docker inspect --format '{{.State.Status}}' umbrel 2>/dev/null || true)"
    restart_policy="$(docker inspect --format '{{.HostConfig.RestartPolicy.Name}}' umbrel 2>/dev/null || true)"
    if [[ "$runtime_state" != "running" ]]; then
      report_umbrel_runtime_truth_failure "top-level-running-state" "not-running"
    elif [[ "$restart_policy" != "always" ]]; then
      report_umbrel_runtime_truth_failure "restart-policy" "not-always"
    else
      report_umbrel_runtime_truth_failure "top-level-container-contract" "not-ready"
    fi
    return 1
  fi

  if system_containers_need_replacement; then
    report_umbrel_runtime_truth_failure "system-container-contract" "not-canonical"
    return 1
  fi

  if ! postcheck_umbrel_safe_shutdown >/dev/null 2>&1; then
    report_umbrel_runtime_truth_failure "safe-shutdown-contract" "not-verified"
    return 1
  fi

  if ! wait_for_umbrel_http >/dev/null 2>&1; then
    report_umbrel_runtime_truth_failure "http-readiness" "not-responsive"
    return 1
  fi
}

finalize_install_state() {
  local version="$1"

  if [[ "$DRY_RUN" -eq 1 ]]; then
    echo "[DRY-RUN] skips live Umbrel runtime verification and final state publication"
    return 0
  fi

  verified_umbrel_runtime_snapshot || return 1
  verify_umbrel_runtime_truth 1 || return 1
  update_install_state finalized "" "$version" "" "$VERIFIED_UMBREL_RUNTIME_IMAGE" "$VERIFIED_UMBREL_RUNTIME_IMAGE_ID"
}

report_umbrel_runtime_truth() {
  if verify_umbrel_runtime_truth; then
    info "Runtime truth diagnostic: predicate=all observed-state=canonical"
    return 0
  fi
  return 1
}

install_state_matches_verified_runtime() {
  local target_version="$1"

  [[ -f "$INSTALL_STATE_FILE" ]] \
    && [[ "$(read_install_state_value version || true)" == "$target_version" ]] \
    && [[ "$(read_install_state_value host_version || true)" == "$target_version" ]] \
    && [[ "$(read_install_state_value image || true)" == "$VERIFIED_UMBREL_RUNTIME_IMAGE" ]] \
    && [[ "$(read_install_state_value image_id || true)" == "$VERIFIED_UMBREL_RUNTIME_IMAGE_ID" ]]
}

repair_current_umbrel_runtime() {
  if ! assert_fullnode_data_mount_safe >/dev/null 2>&1; then
    err "Current-version runtime repair requires proven data identity and an existing top-level Umbrel container."
    return 1
  fi
  if ! begin_umbrel_candidate_transaction 1; then
    fail_umbrel_transaction "current-version runtime repair could not start"
    return 1
  fi
  if ! install_umbrel_safe_shutdown; then
    fail_umbrel_transaction "current-version safe-shutdown repair failed"
    return 1
  fi
  if ! wait_for_postcheck_system_containers; then
    err "Current-version system-container convergence did not complete within bounded readiness attempts."
    fail_umbrel_transaction "current-version system-container convergence did not complete within bounded readiness attempts."
    return 1
  fi
  if ! verify_umbrel_runtime_truth; then
    fail_umbrel_transaction "current-version runtime repair did not converge"
    return 1
  fi
  complete_umbrel_transaction
}

reconcile_current_version_runtime() {
  local target_version="$1"

  if [[ "$CHECK_ONLY" -eq 1 ]]; then
    report_umbrel_runtime_truth
    return
  fi
  if report_umbrel_runtime_truth; then
    if install_state_matches_verified_runtime "$target_version"; then
      info "Current-version runtime and install metadata are already canonical."
      return 0
    fi
    finalize_install_state "$target_version"
    return
  fi
  repair_current_umbrel_runtime || return 1
  finalize_install_state "$target_version"
}

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
  if ! is_numeric_version "$current"; then
    err "Invalid installed version format; expected numeric X.Y.Z."
    return 1
  fi
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
    mark_step_failed "$step" "${UMBREL_TRANSACTION_FAILURE_MESSAGE:-apply failed}"
    UMBREL_TRANSACTION_FAILURE_MESSAGE=""
    return 1
  fi

  info "[$step] Postcheck"
  if ! "$postcheck_fn"; then
    mark_step_failed "$step" "${UMBREL_TRANSACTION_FAILURE_MESSAGE:-postcheck failed}"
    UMBREL_TRANSACTION_FAILURE_MESSAGE=""
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
apply_0_4_10_to_0_4_11() { install_umbrel_safe_shutdown; }
postcheck_0_4_10_to_0_4_11() { postcheck_umbrel_safe_shutdown; }

precheck_0_4_11_to_0_4_12() { precheck_common_canonical_install; }
apply_0_4_11_to_0_4_12() { install_umbrel_safe_shutdown; }
postcheck_0_4_11_to_0_4_12() { postcheck_umbrel_safe_shutdown; }

precheck_0_4_12_to_0_4_13() { precheck_common_canonical_install; }
apply_0_4_12_to_0_4_13() { info "[0.4.13] Documentation-only release; recording migration history"; }
postcheck_0_4_12_to_0_4_13() { precheck_common_canonical_install; }

precheck_0_4_13_to_0_4_14() { precheck_common_canonical_install; }
apply_0_4_13_to_0_4_14() { info "[0.4.14] Fresh installer interactive abort fix; recording migration history"; }
postcheck_0_4_13_to_0_4_14() { precheck_common_canonical_install; }

precheck_0_4_14_to_0_4_15() { precheck_common_canonical_install; }
apply_0_4_14_to_0_4_15() { info "[0.4.15] NVMe-only installer target filtering; recording migration history"; }
postcheck_0_4_14_to_0_4_15() { precheck_common_canonical_install; }

precheck_0_4_15_to_0_4_16() { precheck_common_canonical_install; }
apply_0_4_15_to_0_4_16() { info "[0.4.16] Fresh installer target-scoped SSD busy-process cleanup; recording migration history"; }
postcheck_0_4_15_to_0_4_16() { precheck_common_canonical_install; }

precheck_0_4_16_to_0_4_17() { precheck_common_canonical_install; }
apply_0_4_16_to_0_4_17() { info "[0.4.17] Fresh installer NVMe resume + reinstall stabilization; recording migration history"; }
postcheck_0_4_16_to_0_4_17() { precheck_common_canonical_install; }

precheck_0_4_17_to_0_4_18() { precheck_common_canonical_install; }
apply_0_4_17_to_0_4_18() { info "[0.4.18] CI-only installer compatibility follow-up; recording migration history"; }
postcheck_0_4_17_to_0_4_18() { precheck_common_canonical_install; }

precheck_0_4_18_to_0_5_0() { precheck_common_canonical_install; }
apply_0_4_18_to_0_5_0() { install_fstrim_dropin; }
postcheck_0_4_18_to_0_5_0() {
  local dropin_file="/etc/systemd/system/fstrim.service.d/m1s-no-syscallfilter.conf"
  local host_version="unknown"

  if [[ "$DRY_RUN" -eq 1 ]]; then
    return 0
  fi

  if [[ -r /etc/os-release ]]; then
    # shellcheck disable=SC1091
    source /etc/os-release
    host_version="${VERSION_ID:-unknown}"
  fi

  if [[ "$host_version" != "22.04" ]]; then
    return 0
  fi

  [[ -f "$dropin_file" ]] || { err "fstrim drop-in is missing"; return 1; }
  grep -q '^SystemCallFilter=$' "$dropin_file" || { err "fstrim drop-in did not clear SystemCallFilter"; return 1; }
  grep -q '^SystemCallErrorNumber=$' "$dropin_file" || { err "fstrim drop-in did not clear SystemCallErrorNumber"; return 1; }
}

precheck_0_5_0_to_0_5_1() { precheck_common_canonical_install; }
apply_0_5_0_to_0_5_1() { disable_ufw_for_umbrel; }
postcheck_0_5_0_to_0_5_1() {
  if [[ "$DRY_RUN" -eq 1 ]]; then
    return 0
  fi
  if ufw_is_active; then
    err "UFW is still active after the Umbrel networking simplification step"
    return 1
  fi
}

precheck_0_5_1_to_0_5_2() { precheck_common_canonical_install; }
apply_0_5_1_to_0_5_2() { disable_ufw_for_umbrel; }
postcheck_0_5_1_to_0_5_2() {
  if [[ "$DRY_RUN" -eq 1 ]]; then
    return 0
  fi
  if ufw_is_active; then
    err "UFW is still active after the Umbrel networking simplification step"
    return 1
  fi
}

precheck_0_5_2_to_0_5_3() { precheck_common_canonical_install; }
apply_0_5_2_to_0_5_3() { remove_pwm_fan_config; }
postcheck_0_5_2_to_0_5_3() {
  local config_ini="/boot/config.ini"

  if [[ "$DRY_RUN" -eq 1 ]]; then
    return 0
  fi

  [[ -f "$config_ini" ]] || return 0

  if grep -Eq '^\s*overlay_profile\s*=\s*pwm\s*$' "$config_ini"; then
    err "PWM overlay profile is still present in $config_ini"
    return 1
  fi

  if grep -Eq '^\s*\[overlay_pwm\]\s*$' "$config_ini"; then
    err "overlay_pwm section is still present in $config_ini"
    return 1
  fi

  if grep -Eq '^\s*overlays\s*=.*\b(pwm1|pwm2)\b' "$config_ini"; then
    err "PWM overlay entries are still present in $config_ini"
    return 1
  fi
}

precheck_0_5_3_to_0_5_4() { precheck_common_canonical_install; }
apply_0_5_3_to_0_5_4() { info "0.5.4 was a documentation-only release; no host changes required."; }
postcheck_0_5_3_to_0_5_4() { return 0; }

precheck_0_5_4_to_0_5_5() { precheck_common_canonical_install; }
apply_0_5_4_to_0_5_5() { info "0.5.5 adds operator-side chainstate helper scripts; no host mutation required."; }
postcheck_0_5_4_to_0_5_5() { return 0; }

precheck_0_5_5_to_0_5_6() { precheck_common_canonical_install; }
apply_0_5_5_to_0_5_6() { info "0.5.6 is a documentation-only release; no host changes required."; }
postcheck_0_5_5_to_0_5_6() { return 0; }

precheck_0_5_6_to_0_5_7() { precheck_common_canonical_install; }
apply_0_5_6_to_0_5_7() { info "0.5.7 adds updater repository auto-sync; no host mutation required."; }
postcheck_0_5_6_to_0_5_7() { return 0; }

precheck_0_5_7_to_0_5_8() { precheck_common_canonical_install; }
apply_0_5_7_to_0_5_8() { info "0.5.8 extends fresh-installer NVMe recovery; no host mutation required."; }
postcheck_0_5_7_to_0_5_8() { return 0; }

precheck_0_5_8_to_0_5_9() { precheck_common_canonical_install; }
apply_0_5_8_to_0_5_9() { info "0.5.9 extends fresh-installer SSD-holder cleanup; no host mutation required."; }
postcheck_0_5_8_to_0_5_9() { return 0; }

precheck_0_5_9_to_0_5_10() { precheck_common_canonical_install; }
apply_0_5_9_to_0_5_10() { info "0.5.10 keeps public tracker metadata free of device access details; no host mutation required."; }
postcheck_0_5_9_to_0_5_10() { return 0; }

precheck_0_5_10_to_0_5_11() { precheck_common_canonical_install; }
apply_0_5_10_to_0_5_11() { info "0.5.11 updates public documentation, license metadata, and release helper behavior; no host mutation required."; }
postcheck_0_5_10_to_0_5_11() { return 0; }

precheck_0_5_11_to_0_5_12() { precheck_common_canonical_install; }
apply_0_5_11_to_0_5_12() { info "0.5.12 extends Bitcoin recovery health checks with remote diagnostics; no host mutation required."; }
postcheck_0_5_11_to_0_5_12() { return 0; }

precheck_0_5_12_to_0_5_13() { precheck_common_canonical_install; }
apply_0_5_12_to_0_5_13() { info "0.5.13 adds a one-command system package updater that stops containers before apt upgrades and reboots only when required; no updater host mutation required."; }
postcheck_0_5_12_to_0_5_13() { return 0; }

precheck_0_5_13_to_0_5_14() { precheck_common_canonical_install; }
apply_0_5_13_to_0_5_14() { info "0.5.14 cleans stale legacy /mnt/nvme fstab entries during fresh-install cleanup; no updater host mutation required."; }
postcheck_0_5_13_to_0_5_14() { return 0; }

precheck_0_5_14_to_0_5_15() { return 0; }
apply_0_5_14_to_0_5_15() { info "0.5.15 adds updater self-healing for missing /mnt/fullnode fstab and mount drift; no forced host mutation required."; }
postcheck_0_5_14_to_0_5_15() { return 0; }

precheck_0_5_15_to_0_5_16() {
  assert_fullnode_data_mount_safe

  if [[ "$DRY_RUN" -eq 1 ]]; then
    return 0
  fi

  [[ -f "$INSTALL_STATE_FILE" ]] || { err "$INSTALL_STATE_FILE is missing; refusing 1.7.3 in-place migration."; return 1; }
  python3 -m json.tool "$INSTALL_STATE_FILE" >/dev/null || { err "$INSTALL_STATE_FILE is not valid JSON."; return 1; }
  [[ -w "$DATA_DIR" ]] || { err "$DATA_DIR is not writable; refusing 1.7.3 in-place migration."; return 1; }
  [[ -d "$DATA_DIR/app-data" ]] || warn "[0.5.16] $DATA_DIR/app-data is missing; continuing because some hosts may have a minimal Umbrel state."
}

apply_0_5_15_to_0_5_16() {
  info "[0.5.16] Preparing guarded in-place Umbrel 1.7.3 upgrade"

  local backup_root backup_dir
  backup_root="$INSTALL_STATE_DIR/backups"
  backup_dir="$backup_root/0.5.15-to-0.5.16-$(date +%Y%m%d%H%M%S)"

  if [[ "$DRY_RUN" -eq 1 ]]; then
    echo "[DRY-RUN] mkdir -p $backup_dir"
    echo "[DRY-RUN] capture installed.json, fstab, lsblk, findmnt, docker inspect, and app-data tree into $backup_dir"
  else
    mkdir -p "$backup_dir"
    cp "$INSTALL_STATE_FILE" "$backup_dir/installed.json.before"
    cp "$FSTAB_FILE" "$backup_dir/fstab.before"
    lsblk -o NAME,TYPE,SIZE,FSTYPE,MOUNTPOINT,MODEL,SERIAL > "$backup_dir/lsblk.before.txt" 2>&1 || true
    findmnt -R "$DATA_DIR" > "$backup_dir/findmnt.before.txt" 2>&1 || true
    docker inspect umbrel > "$backup_dir/docker-inspect-umbrel.before.json" 2>&1 || true
    find "$DATA_DIR" -maxdepth 2 -mindepth 1 | sort > "$backup_dir/data-tree.before.txt" 2>&1 || true
    info "[0.5.16] Saved pre-upgrade metadata snapshot to $backup_dir"
  fi

  refresh_umbrel_system_container
  install_umbrel_safe_shutdown
}

postcheck_0_5_15_to_0_5_16() {
  assert_fullnode_data_mount_safe || return 1
  wait_for_umbrel_container || { err "Umbrel container did not become running after 1.7.3 migration"; return 1; }
  verify_umbrel_shutdown_source || { err "Umbrel shutdown() safe-stop container patch is missing after 1.7.3 migration"; return 1; }

  if [[ "$DRY_RUN" -eq 1 ]]; then
    echo "[DRY-RUN] verify $INSTALL_STATE_FILE remains valid and app-data tree still exists after 1.7.3 migration"
    return 0
  fi

  python3 -m json.tool "$INSTALL_STATE_FILE" >/dev/null || { err "$INSTALL_STATE_FILE became invalid JSON after 1.7.3 migration"; return 1; }
  [[ -d "$DATA_DIR/app-data" ]] || warn "[0.5.16] $DATA_DIR/app-data is still missing after migration; verify this host intentionally has no installed apps."
  if command -v curl >/dev/null 2>&1; then
    local http_ready=0
    for _ in {1..30}; do
      if curl -fsS --max-time 10 http://127.0.0.1/ >/dev/null 2>&1; then
        http_ready=1
        break
      fi
      sleep 2
    done
    [[ "$http_ready" -eq 1 ]] || { err "Umbrel HTTP is not ready after 1.7.3 migration"; return 1; }
  fi
}

precheck_0_5_16_to_0_5_17() { precheck_common_canonical_install; }
apply_0_5_16_to_0_5_17() { info "0.5.17 adds graceful stop/restart handling for running Umbrel app containers during top-level system container refreshes; no immediate host mutation required."; }
postcheck_0_5_16_to_0_5_17() { return 0; }

legacy_incus_packages_installed() {
  local package
  for package in "${LEGACY_INCUS_PACKAGES[@]}"; do
    if dpkg-query -W -f='${db:Status-Abbrev}' "$package" 2>/dev/null | grep -q '^i'; then
      printf '%s\n' "$package"
    fi
  done
}

cleanup_legacy_incus_lxd_remnants() {
  local name package path packages_to_purge=()

  info "[0.5.19] Removing legacy Incus/LXD packages and app-layer remnants; Umbrel data in $DATA_DIR is preserved"

  if command -v incus >/dev/null 2>&1; then
    while IFS= read -r name; do
      [[ -z "$name" ]] && continue
      if [[ "$DRY_RUN" -eq 1 ]]; then
        run_cmd incus stop --force "$name"
        run_cmd incus delete --force "$name"
      else
        timeout 20 incus stop --force "$name" || warn "Failed/timed out stopping legacy Incus container: $name (continuing)"
        timeout 20 incus delete --force "$name" || warn "Failed/timed out deleting legacy Incus container: $name (continuing)"
      fi
    done < <(timeout 20 incus list --format csv -c n 2>/dev/null || true)
  fi

  for name in "${LEGACY_INCUS_SERVICES[@]}"; do
    run_cmd systemctl stop "$name" || true
    run_cmd systemctl disable "$name" || true
  done
  run_cmd systemctl reset-failed || true

  run_cmd bash -c "mount | awk '/\/var\/lib\/incus/ {print \$3}' | while read -r mountpoint; do umount -l \"\$mountpoint\" >/dev/null 2>&1 || true; done"

  while IFS= read -r package; do
    [[ -z "$package" ]] && continue
    packages_to_purge+=("$package")
  done < <(legacy_incus_packages_installed)

  if [[ "${#packages_to_purge[@]}" -gt 0 ]]; then
    wait_for_apt_locks
    run_cmd env DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=300 purge -y "${packages_to_purge[@]}"
    run_cmd env DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=300 clean || true
  else
    info "[0.5.19] No installed Incus/LXD apt packages found."
  fi

  if command -v snap >/dev/null 2>&1 && snap list lxd >/dev/null 2>&1; then
    run_cmd snap remove --purge lxd || warn "Failed to remove legacy LXD snap (continuing)"
  fi

  for path in "${LEGACY_INCUS_PATHS[@]}"; do
    if [[ -e "$path" || -L "$path" ]]; then
      run_cmd rm -rf -- "$path"
    fi
  done
}

verify_legacy_incus_lxd_absent() {
  local package remaining=0
  for package in "${LEGACY_INCUS_PACKAGES[@]}"; do
    if dpkg-query -W -f='${db:Status-Abbrev}' "$package" 2>/dev/null | grep -q '^i'; then
      err "Legacy Incus/LXD package still installed after cleanup: $package"
      remaining=1
    fi
  done
  return "$remaining"
}

precheck_0_5_17_to_0_5_18() {
  precheck_common_canonical_install
  ensure_host_data_alias check
}

apply_0_5_17_to_0_5_18() {
  local current_image
  current_image="$(docker inspect umbrel --format '{{.Image}}')"
  [[ -n "$current_image" ]] || { err "Could not determine current umbrel image before /data alias migration."; return 1; }

  info "[0.5.18] Creating $HOST_DATA_ALIAS bind alias for Umbrel Files /Apps compatibility"
  ensure_host_data_alias repair

  if [[ "$(inspect_umbrel_mount_source /data)" == "$HOST_DATA_ALIAS" ]]; then
    info "[0.5.18] Umbrel already uses $HOST_DATA_ALIAS:/data; no container recreation needed."
    return 0
  fi

  info "[0.5.18] Recreating top-level Umbrel container with $HOST_DATA_ALIAS:/data so Files /Apps resolves inside its base directory"
  print_running_app_container_hint
  load_running_app_containers
  if [[ "$DRY_RUN" -eq 1 ]]; then
    echo "[DRY-RUN] stop running app containers, stop/remove umbrel, then recreate umbrel with $HOST_DATA_ALIAS:/data using image $current_image"
    return 0
  fi

  stop_running_app_containers
  docker stop umbrel >/dev/null
  docker rm umbrel >/dev/null
  run_umbrel_container "$current_image" >/dev/null

  if ! wait_for_umbrel_container; then
    rollback_umbrel_container "$current_image"
    return 1
  fi

  start_stopped_app_containers || warn "[0.5.18] Some previously running Umbrel app containers did not restart cleanly after /data alias migration."
  install_umbrel_safe_shutdown
}

postcheck_0_5_17_to_0_5_18() {
  local umbrel_data_source
  ensure_host_data_alias repair
  assert_fullnode_data_mount_safe || return 1
  wait_for_umbrel_container || { err "Umbrel container did not become running after /data alias migration"; return 1; }
  umbrel_data_source="$(inspect_umbrel_mount_source /data)"
  [[ "$umbrel_data_source" == "$HOST_DATA_ALIAS" ]] || { err "Umbrel /data mount is ${umbrel_data_source:-missing}, expected $HOST_DATA_ALIAS after /data alias migration"; return 1; }

  if [[ "$DRY_RUN" -eq 1 ]]; then
    echo "[DRY-RUN] verify umbreld uses --data-directory $HOST_DATA_ALIAS and /Apps realpath stays inside $HOST_DATA_ALIAS/app-data"
    return 0
  fi

  docker exec umbrel pgrep -af 'umbreld.*--data-directory /data' >/dev/null || { err "umbreld is not running with --data-directory /data"; return 1; }
  docker exec umbrel python3 - <<'PY_INNER'
import os, sys
base = '/data/app-data'
real = os.path.realpath(base)
if not real.startswith(base):
    print(f'{base} realpath is {real}, still outside base', file=sys.stderr)
    sys.exit(1)
PY_INNER
}

precheck_0_5_18_to_0_5_19() { precheck_common_canonical_install; }
apply_0_5_18_to_0_5_19() { cleanup_legacy_incus_lxd_remnants; }
postcheck_0_5_18_to_0_5_19() {
  if [[ "$DRY_RUN" -eq 1 ]]; then
    echo "[DRY-RUN] verify legacy Incus/LXD apt packages are absent after cleanup"
    return 0
  fi
  verify_legacy_incus_lxd_absent
}

precheck_0_5_19_to_0_5_20() { precheck_common_canonical_install; }
apply_0_5_19_to_0_5_20() { info "0.5.20 hardens public update guidance, fresh-install image pinning, and release privacy gates; no immediate host mutation required."; }
postcheck_0_5_19_to_0_5_20() { return 0; }

precheck_0_5_20_to_0_5_21() { precheck_common_canonical_install; }
apply_0_5_20_to_0_5_21() { info "0.5.21 keeps the public fresh-install path aligned with fixed hostname and apt-lock hardening; no immediate host mutation required."; }
postcheck_0_5_20_to_0_5_21() { return 0; }

precheck_0_5_21_to_0_5_22() { precheck_common_canonical_install; }
apply_0_5_21_to_0_5_22() { info "0.5.22 updates the public operational-update and Bitcoin recovery guide flow; no immediate host mutation required."; }
postcheck_0_5_21_to_0_5_22() { return 0; }

precheck_0_5_22_to_0_5_23() { precheck_common_canonical_install; }
apply_0_5_22_to_0_5_23() { info "0.5.23 updates the public system-package update guide flow; no immediate host mutation required."; }
postcheck_0_5_22_to_0_5_23() { return 0; }

precheck_0_5_23_to_0_5_24() { precheck_common_canonical_install; }
apply_0_5_23_to_0_5_24() { info "0.5.24 updates the public Bitcoin recovery subsection heading style; no immediate host mutation required."; }
postcheck_0_5_23_to_0_5_24() { return 0; }

precheck_0_5_24_to_0_5_25() {
  assert_fullnode_data_mount_safe || return 1
  [[ -f "$INSTALL_STATE_FILE" ]] || { err "$INSTALL_STATE_FILE is missing; refusing the 1.7.4 transaction."; return 1; }
  python3 -m json.tool "$INSTALL_STATE_FILE" >/dev/null || { err "$INSTALL_STATE_FILE is not valid JSON."; return 1; }
  [[ -w "$DATA_DIR" ]] || { err "$DATA_DIR is not writable; refusing the 1.7.4 transaction."; return 1; }
  docker inspect umbrel >/dev/null 2>&1 || { err "Existing Umbrel top-level container is missing."; return 1; }
}

apply_0_5_24_to_0_5_25() {
  UMBREL_TRANSACTION_FAILURE_MESSAGE=""
  if ! begin_umbrel_candidate_transaction; then
    fail_umbrel_transaction "candidate start failed"
    return 1
  fi
  if ! install_umbrel_safe_shutdown; then
    fail_umbrel_transaction "safe-shutdown patch failed"
    return 1
  fi
}

report_candidate_postcheck_failure() {
  local predicate="$1"
  local observed_state="$2"
  err "Candidate postcheck diagnostic: predicate=$predicate observed-state=$observed_state"
}

postcheck_0_5_24_to_0_5_25() {
  if ! assert_fullnode_data_mount_safe; then
    report_candidate_postcheck_failure "mount-safety" "not-safe"
  elif ! candidate_umbrel_container_ready "$UMBREL_TRANSACTION_TARGET_IMAGE_ID" "$UMBREL_TRANSACTION_DATA_SOURCE"; then
    report_candidate_postcheck_failure "top-level-readiness" "not-ready"
  elif ! wait_for_postcheck_system_containers; then
    report_candidate_postcheck_failure "system-container-readiness" "not-ready"
  elif ! postcheck_umbrel_safe_shutdown; then
    report_candidate_postcheck_failure "safe-shutdown-verification" "not-verified"
  elif ! wait_for_umbrel_http; then
    report_candidate_postcheck_failure "http-readiness" "not-responsive"
  else
    complete_umbrel_transaction
    return 0
  fi

  fail_umbrel_transaction "candidate postcheck failed"
  return 1
}

precheck_0_5_25_to_0_5_26() { precheck_common_canonical_install; }
apply_0_5_25_to_0_5_26() { info "0.5.26 restores the existing-device login guidance; no immediate host mutation required."; }
postcheck_0_5_25_to_0_5_26() { return 0; }

precheck_0_5_26_to_0_5_27() { precheck_common_canonical_install; }
apply_0_5_26_to_0_5_27() { install_umbrel_safe_shutdown; }
postcheck_0_5_26_to_0_5_27() { postcheck_umbrel_safe_shutdown; }

precheck_0_5_27_to_0_5_28() { precheck_common_canonical_install; }
apply_0_5_27_to_0_5_28() { info "0.5.28 reports the validated host profile without blocking other environments; no immediate host mutation required."; }
postcheck_0_5_27_to_0_5_28() { return 0; }

precheck_0_5_28_to_0_5_29() { precheck_common_canonical_install; }
apply_0_5_28_to_0_5_29() {
  info "0.5.29 repairs stale Avahi interface pins without stopping Docker or Umbrel."
  m1s_configure_avahi_mdns
}
postcheck_0_5_28_to_0_5_29() {
  [[ "$DRY_RUN" -eq 1 ]] && return 0
  m1s_avahi_internal_health_check || return 1
  systemctl is-enabled avahi-alias-umbrel.service >/dev/null 2>&1 || { err "avahi-alias-umbrel.service is not enabled after mDNS repair"; return 1; }
}

# ---------------------------------------------------------------------------
# Main flow
# ---------------------------------------------------------------------------

main() {
  parse_args "$@"
  m1s_report_host_support
  require_root
  sync_repository_to_origin_main "$@"

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

if ! build_migration_plan "$CURRENT_VERSION"; then
  err "Refusing to update because the installed version format is invalid."
  exit 1
fi

if version_lt "$TARGET_VERSION" "$CURRENT_VERSION"; then
  echo "Installed version is newer than this updater target; no repair or state publication will run."
  return 0
fi

if [[ "${#PLANNED_MIGRATIONS[@]}" -eq 0 ]]; then
  reconcile_current_version_runtime "$TARGET_VERSION"
  return
fi

if [[ "$CHECK_ONLY" -eq 1 ]]; then
  ensure_fullnode_mount_from_state check
else
  ensure_fullnode_mount_from_state repair
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

if ! finalize_install_state "$TARGET_VERSION"; then
  err "Final install state was not published because live Umbrel runtime verification failed."
  exit 1
fi

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
