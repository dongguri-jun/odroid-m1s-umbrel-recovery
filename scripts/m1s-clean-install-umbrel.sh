#!/usr/bin/env bash
set -Eeuo pipefail

DRY_RUN=0
RELEASE_MODE=0
IMAGE="dockurr/umbrel"
DATA_DIR="/mnt/fullnode"
PRESERVE_TAILSCALE=1
TARGET_PARTITION=""
TARGET_INPUT=""
TARGET_MODE="partition"
TARGET_DISK_PATH=""
TARGET_INPUT_RESOLVED=""
EXISTING_TARGET_MOUNT=""
TARGET_EXISTING_PARTITIONS=()
TARGET_MOUNT_PATHS=()
TARGET_SWAP_PATHS=()

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

run_shell() {
  if [[ "$DRY_RUN" -eq 1 ]]; then
    printf '[DRY-RUN] bash -lc %q\n' "$1"
    return 0
  fi
  bash -lc "$1"
}

service_exists() {
  systemctl list-unit-files "$1" >/dev/null 2>&1
}

is_preserved_service() {
  local svc="$1"
  local preserved
  for preserved in "${PRESERVED_SERVICES[@]}"; do
    [[ "$svc" == "$preserved" ]] && return 0
  done
  return 1
}

append_unique() {
  local value="$1"
  shift
  local existing
  for existing in "$@"; do
    [[ "$existing" == "$value" ]] && return 1
  done
  return 0
}

user_exists() {
  id "$1" >/dev/null 2>&1
}

remove_path() {
  local path="$1"
  if [[ -e "$path" || -L "$path" ]]; then
    run_cmd rm -rf -- "$path"
  fi
}

partition_path_for_disk() {
  local disk_path="$1"
  local disk_name
  disk_name="$(basename "$disk_path")"
  if [[ "$disk_name" =~ [0-9]$ ]]; then
    printf '%sp1\n' "$disk_path"
  else
    printf '%s1\n' "$disk_path"
  fi
}

wait_for_block_device() {
  local path="$1"
  local attempts="${2:-10}"
  local i
  for ((i=0; i<attempts; i++)); do
    [[ -b "$path" ]] && return 0
    sleep 1
  done
  return 1
}

resolve_block_path() {
  local path="$1"
  if command -v readlink >/dev/null 2>&1; then
    readlink -f -- "$path" 2>/dev/null || printf '%s\n' "$path"
  elif command -v realpath >/dev/null 2>&1; then
    realpath "$path" 2>/dev/null || printf '%s\n' "$path"
  else
    printf '%s\n' "$path"
  fi
}

guess_parent_disk_path() {
  local path="$1"
  if [[ "$path" =~ ^(/dev/.+)p[0-9]+$ ]]; then
    printf '%s\n' "${BASH_REMATCH[1]}"
  elif [[ "$path" =~ ^(/dev/[a-z]+)[0-9]+$ ]]; then
    printf '%s\n' "${BASH_REMATCH[1]}"
  else
    printf '%s\n' ""
  fi
}

select_target_disk_interactive() {
  local candidate_paths=()
  local candidate_sizes=()
  local candidate_models=()
  local candidate_mounts=()
  local candidate_parts=()
  local disk_path size model mounts part_count disk_name choice index line name type

  if [[ -z "$ROOT_DISK" ]]; then
    err "Could not determine the current root/system disk automatically."
    err "For safety, rerun with --target-partition and specify the intended SSD disk or partition explicitly."
    exit 1
  fi

  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    unset NAME SIZE TYPE MODEL name size type model
    eval "$line"
    [[ "${TYPE:-}" == "disk" ]] || continue
    disk_path="/dev/${NAME}"
    size="${SIZE:-unknown}"
    model="${MODEL:-unknown}"
    [[ -z "$disk_path" ]] && continue
    disk_name="$(basename "$disk_path")"
    if [[ -n "$ROOT_DISK" && "$disk_name" == "$ROOT_DISK" ]]; then
      continue
    fi

    mounts="$(lsblk -nrpo MOUNTPOINT "$disk_path" 2>/dev/null | awk 'NF' | paste -sd ', ' -)"
    [[ -n "$mounts" ]] || mounts="NOT_MOUNTED"
    part_count="$(lsblk -nrpo NAME,TYPE "$disk_path" 2>/dev/null | awk '$2 == "part" {count++} END {print count+0}')"

    candidate_paths+=("$disk_path")
    candidate_sizes+=("$size")
    candidate_models+=("${model:-unknown}")
    candidate_mounts+=("$mounts")
    candidate_parts+=("$part_count")
  done < <(lsblk -dn -o NAME,SIZE,TYPE,MODEL -P 2>/dev/null)

  if [[ "${#candidate_paths[@]}" -eq 0 ]]; then
    err "No candidate storage disks were found."
    exit 1
  fi

  echo
  echo "Detected non-root storage disks:"
  for index in "${!candidate_paths[@]}"; do
    printf '  %d) %s  size=%s  model=%s  partitions=%s  mounts=%s\n' \
      "$((index + 1))" \
      "${candidate_paths[$index]}" \
      "${candidate_sizes[$index]}" \
      "${candidate_models[$index]}" \
      "${candidate_parts[$index]}" \
      "${candidate_mounts[$index]}"
  done

  while true; do
    read -r -p "Choose the storage disk to initialize [1-${#candidate_paths[@]}]: " choice
    if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#candidate_paths[@]} )); then
      TARGET_INPUT="${candidate_paths[$((choice - 1))]}"
      return 0
    fi
    warn "Invalid selection. Please enter a number from 1 to ${#candidate_paths[@]}."
  done
}

usage() {
  cat <<'EOF'
ODROID M1S Ubuntu cleanup + Umbrel Docker installer

Usage:
  sudo bash m1s-clean-install-umbrel.sh [options]

Options:
  --dry-run                  Show actions without changing anything
  --release                  Release mode: remove tailscale too
  --image IMAGE              Docker image to run (default: dockurr/umbrel)
  --data-dir PATH            Umbrel data directory (default: /mnt/fullnode)
  --target-partition PATH    Target SSD disk or partition to initialize
  --remove-tailscale         Alias for --release
  -h, --help                 Show this help

Examples:
  sudo bash m1s-clean-install-umbrel.sh --dry-run
  sudo bash m1s-clean-install-umbrel.sh --data-dir /mnt/fullnode
  sudo bash m1s-clean-install-umbrel.sh --image tao9317/tao-umbrel --data-dir /mnt/fullnode
  sudo bash m1s-clean-install-umbrel.sh --target-partition /dev/nvme0n1
  sudo bash m1s-clean-install-umbrel.sh --target-partition /dev/nvme0n1p1
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)
      DRY_RUN=1
      ;;
    --release)
      RELEASE_MODE=1
      PRESERVE_TAILSCALE=0
      ;;
    --image)
      IMAGE="$2"
      shift
      ;;
    --data-dir)
      DATA_DIR="$2"
      shift
      ;;
    --target-partition)
      TARGET_PARTITION="$2"
      shift
      ;;
    --remove-tailscale)
      RELEASE_MODE=1
      PRESERVE_TAILSCALE=0
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

TARGET_INPUT="$TARGET_PARTITION"

if [[ "${EUID}" -ne 0 ]]; then
  err "Run this script with sudo or as root."
  exit 1
fi

source /etc/os-release
if [[ "${ID:-}" != "ubuntu" ]]; then
  err "This script supports Ubuntu only. Detected: ${ID:-unknown}"
  exit 1
fi

case "${VERSION_ID:-}" in
  20.04|22.04|24.04)
    ;;
  *)
    err "Unsupported Ubuntu version: ${VERSION_ID:-unknown}. Supported: 20.04, 22.04, 24.04"
    exit 1
    ;;
esac

ARCH="$(uname -m)"
if [[ "$ARCH" != "aarch64" && "$ARCH" != "arm64" ]]; then
  err "This script is intended for ARM64 only. Detected: $ARCH"
  exit 1
fi

MODEL="unknown"
if [[ -r /proc/device-tree/model ]]; then
  MODEL="$(tr -d '\0' </proc/device-tree/model)"
elif [[ -r /sys/firmware/devicetree/base/model ]]; then
  MODEL="$(tr -d '\0' </sys/firmware/devicetree/base/model)"
fi
if [[ "$MODEL" != "unknown" && "$MODEL" != *"ODROID-M1S"* ]]; then
  err "This script is intended for ODROID-M1S only. Detected model: $MODEL"
  exit 1
fi

ROOT_SOURCE="$(findmnt -n -o SOURCE / || true)"
ROOT_DISK="$(lsblk -no PKNAME "$ROOT_SOURCE" 2>/dev/null | head -n1 || true)"
TARGET_DISK=""
CURRENT_DATA_SOURCE="$(findmnt -n -o SOURCE --target "$DATA_DIR" 2>/dev/null || true)"
EXISTING_TARGET_MOUNT=""

if [[ -z "$TARGET_INPUT" ]]; then
  select_target_disk_interactive
fi

TARGET_INPUT_RESOLVED="$(resolve_block_path "$TARGET_INPUT")"

if [[ -b "$TARGET_INPUT" ]]; then
  TARGET_INPUT_RESOLVED="$(resolve_block_path "$TARGET_INPUT")"
  TARGET_TYPE="$(lsblk -dn -o TYPE "$TARGET_INPUT_RESOLVED" 2>/dev/null | head -n1 || true)"
  case "$TARGET_TYPE" in
    part)
      TARGET_MODE="partition"
      TARGET_PARTITION="$TARGET_INPUT_RESOLVED"
      TARGET_DISK="$(lsblk -no PKNAME "$TARGET_PARTITION" 2>/dev/null | head -n1 || true)"
      TARGET_DISK_PATH="/dev/$TARGET_DISK"
      EXISTING_TARGET_MOUNT="$(findmnt -rn -S "$TARGET_PARTITION" -o TARGET 2>/dev/null | head -n1 || true)"
      ;;
    disk)
      TARGET_MODE="raw-disk"
      TARGET_DISK_PATH="$TARGET_INPUT_RESOLVED"
      TARGET_DISK="$(basename "$TARGET_DISK_PATH")"
      TARGET_PARTITION="$(partition_path_for_disk "$TARGET_DISK_PATH")"
      ;;
    *)
      err "Target path must be a partition or disk block device: $TARGET_INPUT"
      exit 1
      ;;
  esac
else
  TARGET_DISK_PATH="$(guess_parent_disk_path "$TARGET_INPUT")"
  TARGET_DISK_PATH="$(resolve_block_path "$TARGET_DISK_PATH")"
  if [[ -n "$TARGET_DISK_PATH" ]]; then
    if [[ -b "$TARGET_DISK_PATH" ]]; then
      TARGET_MODE="raw-disk"
      TARGET_DISK="$(basename "$TARGET_DISK_PATH")"
    fi
  fi

  if [[ "$TARGET_MODE" == "raw-disk" ]]; then
    TARGET_PARTITION="$(partition_path_for_disk "$TARGET_DISK_PATH")"
  else
    err "Target partition does not exist: $TARGET_INPUT"
    exit 1
  fi
fi

if [[ -z "$TARGET_DISK" ]]; then
  err "Could not determine target disk for: $TARGET_INPUT"
  exit 1
fi

if [[ -n "$ROOT_DISK" && "$TARGET_DISK" == "$ROOT_DISK" ]]; then
  err "Refusing to format the root/system disk. Root disk: /dev/$ROOT_DISK, target: $TARGET_PARTITION"
  exit 1
fi

if [[ "$TARGET_DISK" != nvme* ]]; then
  warn "Target partition parent disk is /dev/$TARGET_DISK, not an nvme device."
fi

if [[ "$TARGET_MODE" == "partition" ]]; then
  TARGET_EXISTING_PARTITIONS+=("$TARGET_PARTITION")
  EXISTING_TARGET_MOUNT="$(findmnt -rn -S "$TARGET_PARTITION" -o TARGET 2>/dev/null | head -n1 || true)"
  if [[ -n "$EXISTING_TARGET_MOUNT" ]] && append_unique "$EXISTING_TARGET_MOUNT" "${TARGET_MOUNT_PATHS[@]}"; then
    TARGET_MOUNT_PATHS+=("$EXISTING_TARGET_MOUNT")
  fi
else
  if append_unique "$TARGET_DISK_PATH" "${TARGET_EXISTING_PARTITIONS[@]}"; then
    TARGET_EXISTING_PARTITIONS+=("$TARGET_DISK_PATH")
  fi
  disk_mount="$(findmnt -rn -S "$TARGET_DISK_PATH" -o TARGET 2>/dev/null | head -n1 || true)"
  if [[ -n "$disk_mount" ]] && append_unique "$disk_mount" "${TARGET_MOUNT_PATHS[@]}"; then
    TARGET_MOUNT_PATHS+=("$disk_mount")
  fi
  while IFS= read -r child_name; do
    [[ -z "$child_name" ]] && continue
    if append_unique "$child_name" "${TARGET_EXISTING_PARTITIONS[@]}"; then
      TARGET_EXISTING_PARTITIONS+=("$child_name")
    fi
    child_mount="$(findmnt -rn -S "$child_name" -o TARGET 2>/dev/null | head -n1 || true)"
    if [[ -n "$child_mount" ]] && append_unique "$child_mount" "${TARGET_MOUNT_PATHS[@]}"; then
      TARGET_MOUNT_PATHS+=("$child_mount")
    fi
  done < <(lsblk -nrpo NAME,TYPE "$TARGET_DISK_PATH" 2>/dev/null | awk '$2 == "part" {print $1}')
  EXISTING_TARGET_MOUNT="${TARGET_MOUNT_PATHS[*]:-}"
fi

while IFS= read -r swap_path; do
  [[ -z "$swap_path" ]] && continue
  if append_unique "$swap_path" "${TARGET_SWAP_PATHS[@]}"; then
    TARGET_SWAP_PATHS+=("$swap_path")
  fi
done < <(swapon --noheadings --raw --output=NAME 2>/dev/null | while read -r p; do
  [[ -n "$p" ]] || continue
  for target_dev in "${TARGET_EXISTING_PARTITIONS[@]}"; do
    if [[ "$p" == "$target_dev" ]]; then
      printf '%s\n' "$p"
      continue 2
    fi
  done
  for mount_path in "${TARGET_MOUNT_PATHS[@]}"; do
    if [[ -n "$mount_path" && "$p" == "$mount_path"* ]]; then
      printf '%s\n' "$p"
      continue 2
    fi
  done
done)

cat <<EOF

=== ODROID M1S Cleanup + Umbrel Installer ===
Model:              $MODEL
OS:                 Ubuntu ${VERSION_ID}
Architecture:       $ARCH
Root filesystem:    ${ROOT_SOURCE:-unknown}
Umbrel image:       $IMAGE
Umbrel data dir:    $DATA_DIR
Target input:       $TARGET_INPUT
Target partition:   $TARGET_PARTITION
Target mode:        $TARGET_MODE
Existing mount:     ${EXISTING_TARGET_MOUNT:-NOT_MOUNTED}
Current data mount: ${CURRENT_DATA_SOURCE:-NOT_MOUNTED}
Preserve Tailscale: $PRESERVE_TAILSCALE
Release mode:       $RELEASE_MODE
Dry run:            $DRY_RUN

This script will:
  1. stop and remove RaspiBlitz / Incus / LXD / Docker workloads
  2. remove custom services, app packages, and app data from eMMC
  3. preserve Ubuntu base install, boot, networking, SSH, cloud-init, and the current sudo user
  4. FORMAT the SSD partition and mount it at $DATA_DIR
  5. install Docker fresh
  6. start Umbrel as a Docker container

This script WILL erase all existing data on the selected SSD target.
EOF

if [[ "$DRY_RUN" -eq 0 ]]; then
  echo
  warn "This is destructive for services and files stored on eMMC."
  if [[ "$TARGET_MODE" == "raw-disk" ]]; then
    warn "This will repartition $TARGET_DISK_PATH, create $TARGET_PARTITION, and erase all existing SSD data on that disk."
  else
    warn "This will also format $TARGET_PARTITION and erase all existing SSD data on that partition."
  fi
  read -r -p "Type ERASE-EMMC-AND-FORMAT-SSD-AND-INSTALL-UMBREL to continue: " CONFIRM
  if [[ "$CONFIRM" != "ERASE-EMMC-AND-FORMAT-SSD-AND-INSTALL-UMBREL" ]]; then
    err "Confirmation text mismatch. Aborting."
    exit 1
  fi
fi

PRESERVED_SERVICES=(
  ssh.service
  sshd.service
  systemd-networkd.service
  systemd-resolved.service
  networkd-dispatcher.service
  NetworkManager.service
  dbus.service
  systemd-timesyncd.service
  cron.service
  cloud-config.service
  cloud-final.service
  cloud-init-local.service
  cloud-init.service
)

info "Stopping and removing Incus containers if present"
if command -v incus >/dev/null 2>&1; then
  while IFS= read -r name; do
    [[ -z "$name" ]] && continue
    if [[ "$DRY_RUN" -eq 1 ]]; then
      run_cmd incus stop --force "$name" || warn "Failed to stop Incus container: $name (continuing)"
      run_cmd incus delete --force "$name" || warn "Failed to delete Incus container: $name (continuing)"
    else
      timeout 20 incus stop --force "$name" || warn "Failed/timed out stopping Incus container: $name (continuing)"
      timeout 20 incus delete --force "$name" || warn "Failed/timed out deleting Incus container: $name (continuing)"
    fi
  done < <(timeout 20 incus list --format csv -c n 2>/dev/null || true)
fi

info "Stopping and removing Docker containers if present"
if command -v docker >/dev/null 2>&1; then
  while IFS= read -r cid; do
    [[ -z "$cid" ]] && continue
    run_cmd docker rm -f "$cid"
  done < <(docker ps -aq 2>/dev/null || true)
  run_shell 'docker system prune -af --volumes || true'
fi

APP_SERVICES=(
  background.service
  background.scan.service
  bitcoind.service
  blitzapi.service
  electrs.service
  i2pd.service
  incus-lxcfs.service
  nginx.service
  redis-server.service
  tor@default.service
  snap.lxd.daemon.service
  snap.lxd.daemon.unix.socket
  tailscaled.service
)

while IFS= read -r detected_svc; do
  [[ -z "$detected_svc" ]] && continue
  if is_preserved_service "$detected_svc"; then
    continue
  fi
  if append_unique "$detected_svc" "${APP_SERVICES[@]}"; then
    APP_SERVICES+=("$detected_svc")
  fi
done < <(systemctl list-unit-files --type=service --no-legend 2>/dev/null | awk '{print $1}' | grep -E '^(background|bitcoind|blitz|electrs|incus|nginx|redis|tor|i2pd|tailscaled|lnd|rtl|mempool|btcpay).*\.service$' || true)

if [[ "$PRESERVE_TAILSCALE" -eq 1 ]]; then
  APP_SERVICES=("${APP_SERVICES[@]/tailscaled.service}")
fi

info "Stopping and disabling app-layer services only"
for svc in "${APP_SERVICES[@]}"; do
  [[ -z "$svc" ]] && continue
  if is_preserved_service "$svc"; then
    warn "Skipping preserved service: $svc"
    continue
  fi
  if service_exists "$svc"; then
    run_cmd systemctl stop "$svc" || warn "Failed to stop service: $svc (continuing)"
    run_cmd systemctl disable "$svc" || warn "Failed to disable service: $svc (continuing)"
  fi
done

info "Removing custom systemd unit files"
CUSTOM_UNITS=(
  /etc/systemd/system/background.service
  /etc/systemd/system/background.scan.service
  /etc/systemd/system/bitcoind.service
  /etc/systemd/system/blitzapi.service
  /etc/systemd/system/electrs.service
  /etc/systemd/system/bitcoind.service.backup.1775235850
  /etc/systemd/system/electrs.service.backup.1775235850
  /etc/systemd/system/nginx.service.d
  /etc/systemd/system/tor@default.service.d
)
for path in "${CUSTOM_UNITS[@]}"; do
  remove_path "$path"
done
run_cmd systemctl daemon-reload
run_cmd systemctl reset-failed

info "Purging app-specific packages only"
APT_PACKAGES=(
  incus
  incus-base
  incus-client
  lxd-agent-loader
  nginx
  nginx-common
  nginx-full
  redis-server
  tor
  tor-geoipdb
  torsocks
  nyx
  obfs4proxy
  i2pd
  apt-transport-tor
  docker.io
  docker-ce
  docker-ce-cli
  docker-buildx-plugin
  docker-compose-plugin
  containerd
  containerd.io
  runc
)
if [[ "$PRESERVE_TAILSCALE" -eq 0 ]]; then
  APT_PACKAGES+=(tailscale)
fi
run_shell "DEBIAN_FRONTEND=noninteractive apt-get purge -y ${APT_PACKAGES[*]} || true"
run_shell 'apt-get clean || true'

info "Removing LXD snap if present"
if command -v snap >/dev/null 2>&1; then
  if snap list lxd >/dev/null 2>&1; then
    run_cmd snap remove --purge lxd || warn "Failed to remove lxd snap (continuing)"
  fi
fi

info "Detaching lingering Incus/LXD mounts if present"
for svc in incus.service incus.socket incus-lxcfs.service snap.lxd.daemon.service snap.lxd.daemon.unix.socket; do
  if service_exists "$svc"; then
    run_cmd systemctl stop "$svc" || true
    run_cmd systemctl disable "$svc" || true
  fi
done
run_shell "mount | awk '/\/var\/lib\/incus/ {print \$3}' | while read -r m; do umount -l \"\$m\" >/dev/null 2>&1 || true; done"

info "Detaching RaspiBlitz tmpfs mounts if present"
run_shell "umount -l /var/cache/raspiblitz >/dev/null 2>&1 || true"

info "Removing RaspiBlitz and service data from eMMC"
PATHS_TO_REMOVE=(
  /home/admin
  /home/bitcoin
  /home/blitzapi
  /home/electrs
  /var/lib/incus
  /var/lib/lxd
  /var/snap/lxd
  /var/cache/raspiblitz
  /etc/nginx
  /etc/tor
  /etc/redis
  /root/.cache/incus
  /root/.config/incus
)
for path in "${PATHS_TO_REMOVE[@]}"; do
  remove_path "$path" || warn "Failed to remove path: $path (continuing)"
done

info "Removing manually installed Bitcoin binaries"
for bin in /usr/local/bin/bitcoin*; do
  [[ -e "$bin" ]] || continue
  run_cmd rm -f -- "$bin"
done

info "Removing dedicated service accounts"
USERS_TO_REMOVE=(admin bitcoin blitzapi electrs)
for user in "${USERS_TO_REMOVE[@]}"; do
  if user_exists "$user"; then
    run_cmd userdel -r "$user"
  fi
done

info "Cleaning fstab entries that belong to RaspiBlitz eMMC setup"
TARGET_SWAP_PATHS_STR="${TARGET_SWAP_PATHS[*]}"
TARGET_MOUNT_PATHS_STR="${TARGET_MOUNT_PATHS[*]}"
TARGET_EXISTING_PARTITIONS_STR="${TARGET_EXISTING_PARTITIONS[*]}"
run_shell "TARGET_MOUNT_PATHS_STR=${TARGET_MOUNT_PATHS_STR@Q} DATA_DIR_VALUE=${DATA_DIR@Q} TARGET_SWAP_PATHS_STR=${TARGET_SWAP_PATHS_STR@Q} TARGET_EXISTING_PARTITIONS_STR=${TARGET_EXISTING_PARTITIONS_STR@Q} python3 - <<'PY'
from pathlib import Path
import os
fstab = Path('/etc/fstab')
text = fstab.read_text()
lines = text.splitlines()
filtered = []
target_mounts = [p for p in os.environ.get('TARGET_MOUNT_PATHS_STR', '').split() if p]
data_dir = os.environ.get('DATA_DIR_VALUE', '')
target_swaps = [p for p in os.environ.get('TARGET_SWAP_PATHS_STR', '').split() if p]
target_devices = [p for p in os.environ.get('TARGET_EXISTING_PARTITIONS_STR', '').split() if p]
for line in lines:
    stripped = line.strip()
    if not stripped or stripped.startswith('#'):
        filtered.append(line)
        continue
    if '/var/cache/raspiblitz' in stripped:
        continue
    parts = stripped.split()
    if len(parts) < 2:
        filtered.append(line)
        continue
    source, mountpoint = parts[0], parts[1]
    if mountpoint in target_mounts:
        continue
    if data_dir and mountpoint == data_dir:
        continue
    if source in target_swaps:
        continue
    if source in target_devices:
        continue
    filtered.append(line)
new = '\n'.join(filtered) + ('\n' if text.endswith('\n') else '')
if new != text:
    fstab.write_text(new)
PY"

info "Formatting and mounting SSD for Umbrel data"
run_cmd mkdir -p "$DATA_DIR"
if command -v fuser >/dev/null 2>&1; then
  info "Checking for processes still using the current SSD mount"
  for mount_path in "${TARGET_MOUNT_PATHS[@]}"; do
    [[ -n "$mount_path" ]] || continue
    run_shell "fuser -vm '$mount_path' || true"
  done
fi
if [[ "$DRY_RUN" -eq 1 ]]; then
  for swap_path in "${TARGET_SWAP_PATHS[@]}"; do
    run_shell "swapoff '$swap_path' >/dev/null 2>&1 || true"
  done
  for mount_path in "${TARGET_MOUNT_PATHS[@]}"; do
    [[ -n "$mount_path" ]] || continue
    run_shell "umount '$mount_path' >/dev/null 2>&1 || true"
  done
  for target_dev in "${TARGET_EXISTING_PARTITIONS[@]}"; do
    [[ -n "$target_dev" ]] || continue
    run_shell "umount '$target_dev' >/dev/null 2>&1 || true"
  done
  if [[ "$TARGET_MODE" == "partition" ]]; then
    run_shell "umount '$TARGET_PARTITION' >/dev/null 2>&1 || true"
  fi
  run_shell "umount '$DATA_DIR' >/dev/null 2>&1 || true"
else
  for swap_path in "${TARGET_SWAP_PATHS[@]}"; do
    bash -lc "swapoff '$swap_path' >/dev/null 2>&1 || true"
  done
  while IFS= read -r active_swap; do
    [[ -z "$active_swap" ]] && continue
    err "Target swap is still active after swapoff attempt: $active_swap"
    err "Disable swap users on the SSD and try again."
    exit 1
  done < <(swapon --noheadings --raw --output=NAME 2>/dev/null | while read -r p; do
    [[ -n "$p" ]] || continue
    for swap_path in "${TARGET_SWAP_PATHS[@]}"; do
      if [[ "$p" == "$swap_path" ]]; then
        printf '%s\n' "$p"
        continue 2
      fi
    done
  done)
  for mount_path in "${TARGET_MOUNT_PATHS[@]}"; do
    [[ -n "$mount_path" ]] || continue
    bash -lc "umount '$mount_path' >/dev/null 2>&1 || true"
  done
  for target_dev in "${TARGET_EXISTING_PARTITIONS[@]}"; do
    [[ -n "$target_dev" ]] || continue
    bash -lc "umount '$target_dev' >/dev/null 2>&1 || true"
  done
  if [[ "$TARGET_MODE" == "partition" ]]; then
    bash -lc "umount '$TARGET_PARTITION' >/dev/null 2>&1 || true"
  fi
  bash -lc "umount '$DATA_DIR' >/dev/null 2>&1 || true"

  for target_dev in "${TARGET_EXISTING_PARTITIONS[@]}"; do
    [[ -n "$target_dev" ]] || continue
    if findmnt -rn -S "$target_dev" >/dev/null 2>&1; then
      err "Target device is still mounted after unmount attempt: $target_dev"
      err "Stop remaining processes using the SSD and try again."
      exit 1
    fi
  done

  CURRENT_DATA_SOURCE="$(findmnt -rn -o SOURCE -T "$DATA_DIR" 2>/dev/null || true)"
  if [[ -n "$CURRENT_DATA_SOURCE" && "$CURRENT_DATA_SOURCE" != "$ROOT_SOURCE" && "$CURRENT_DATA_SOURCE" != "tmpfs" ]]; then
    err "Data directory is still backed by a non-root mounted filesystem after unmount attempt: $DATA_DIR -> $CURRENT_DATA_SOURCE"
    err "Stop remaining processes using the SSD and try again."
    exit 1
  fi
fi

if [[ "$TARGET_MODE" == "raw-disk" ]]; then
  info "Creating a fresh GPT partition on raw SSD $TARGET_DISK_PATH"
  if ! command -v sfdisk >/dev/null 2>&1; then
    err "sfdisk is required to create a partition on raw SSD targets, but it is not installed."
    exit 1
  fi
  run_shell "printf ',,L\n' | sfdisk --label gpt '$TARGET_DISK_PATH'"
  if command -v partprobe >/dev/null 2>&1; then
    run_cmd partprobe "$TARGET_DISK_PATH"
  fi
  if command -v udevadm >/dev/null 2>&1; then
    run_cmd udevadm settle
  fi
  if [[ "$DRY_RUN" -eq 0 ]]; then
    if ! wait_for_block_device "$TARGET_PARTITION" 15; then
      err "Partition creation completed but target partition did not appear: $TARGET_PARTITION"
      exit 1
    fi
  fi
fi

run_cmd mkfs.ext4 -F "$TARGET_PARTITION"

TARGET_UUID_CMD="blkid -s UUID -o value '$TARGET_PARTITION'"
TARGET_UUID=""
if [[ "$DRY_RUN" -eq 1 ]]; then
  TARGET_UUID="DRYRUN-UUID"
else
  TARGET_UUID="$(bash -lc "$TARGET_UUID_CMD")"
fi

if [[ -z "$TARGET_UUID" ]]; then
  err "Could not determine UUID for $TARGET_PARTITION after formatting."
  exit 1
fi

run_cmd mount "$TARGET_PARTITION" "$DATA_DIR"
run_cmd chown -R root:root "$DATA_DIR"

run_shell "python3 - <<'PY'
from pathlib import Path
fstab = Path('/etc/fstab')
entry = 'UUID=${TARGET_UUID}\t${DATA_DIR}\text4\tdefaults,auto,exec,rw\t0\t0\n'
with fstab.open('a') as f:
    if not f.tell() == 0:
        pass
    f.write(entry)
PY"

CURRENT_DATA_SOURCE="$(findmnt -n -o SOURCE --target "$DATA_DIR" 2>/dev/null || true)"
if [[ "$DRY_RUN" -eq 0 && "$CURRENT_DATA_SOURCE" != "$TARGET_PARTITION" ]]; then
  err "Mount verification failed. Expected $TARGET_PARTITION at $DATA_DIR, got ${CURRENT_DATA_SOURCE:-NOT_MOUNTED}."
  exit 1
fi

info "Installing fresh Docker"
run_shell 'curl -fsSL https://get.docker.com | sh'
run_cmd systemctl enable docker
run_cmd systemctl start docker

if [[ -n "${SUDO_USER:-}" && "${SUDO_USER}" != "root" ]]; then
  run_cmd usermod -aG docker "$SUDO_USER"
fi

info "Pulling and starting Umbrel"
run_cmd docker pull "$IMAGE"
run_shell "docker rm -f umbrel >/dev/null 2>&1 || true"
run_cmd docker run -d --name umbrel --restart always -p 80:80 -v "$DATA_DIR:/data" -v /var/run/docker.sock:/var/run/docker.sock --stop-timeout 60 --pid=host --privileged "$IMAGE"

info "Done."
cat <<EOF

Umbrel container has been started.
Open: http://<device-ip>
Image: $IMAGE
Data directory: $DATA_DIR

If you used --dry-run, no changes were made.
If Docker group membership was updated for your user, log out and back in before using docker without sudo.
EOF
