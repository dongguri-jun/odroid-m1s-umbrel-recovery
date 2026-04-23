#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_VERSION="0.3.0"
INSTALL_STATE_DIR="/etc/umbrel-recovery"
INSTALL_STATE_FILE="$INSTALL_STATE_DIR/installed.json"

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
PRESERVED_PATHS=(
  /var/lib/fullnode-mount-guard
  /usr/local/sbin/fullnode-mount-guard.sh
  /etc/systemd/system/fullnode-mount-guard.service
  /etc/systemd/system/fullnode-mount-guard.timer
  /etc/systemd/system/docker.service.d/require-fullnode.conf
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

run_shell() {
  if [[ "$DRY_RUN" -eq 1 ]]; then
    printf '[DRY-RUN] bash -lc %q\n' "$1"
    return 0
  fi
  bash -lc "$1"
}

# Wait for apt/dpkg locks to be released. Freshly installed Ubuntu Server
# runs unattended-upgrades in the background right after first boot, which
# holds /var/lib/dpkg/lock-frontend and causes `apt-get`-based installers
# (including docker get.docker.com) to fail with lock errors.
#
# This helper polls the common locks for up to 15 minutes. On timeout it
# warns and asks the user to continue or abort.
wait_for_apt_locks() {
  if [[ "$DRY_RUN" -eq 1 ]]; then
    echo "[DRY-RUN] wait for apt/dpkg locks to be released"
    return 0
  fi
  local locks=(/var/lib/dpkg/lock-frontend /var/lib/dpkg/lock /var/lib/apt/lists/lock)
  local max_wait=900   # 15 minutes
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
  err "apt/dpkg locks were still held after 15 minutes."
  err "The most common cause is unattended-upgrades running a long upgrade."
  err "You can check with:  ps -ef | grep -i unattended"
  err "Rerun this script after the update finishes, or stop the upgrade manually."
  exit 1
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

is_preserved_path() {
  local path="$1"
  local preserved
  for preserved in "${PRESERVED_PATHS[@]}"; do
    [[ "$path" == "$preserved" ]] && return 0
    [[ "$path" == "$preserved"/* ]] && return 0
  done
  return 1
}

user_exists() {
  id "$1" >/dev/null 2>&1
}

remove_path() {
  local path="$1"
  if is_preserved_path "$path"; then
    warn "Skipping preserved path: $path"
    return 0
  fi
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
      local selected="${candidate_paths[$((choice - 1))]}"
      local selected_name
      selected_name="$(basename "$selected")"
      if [[ "$selected_name" != nvme* ]]; then
        echo
        warn "WARNING: '$selected' is NOT an NVMe device."
        warn "This script is designed for NVMe SSD. Formatting a non-NVMe device may destroy important data."
        read -r -p "Type YES-USE-THIS-DISK to proceed with this non-NVMe disk: " non_nvme_confirm
        if [[ "$non_nvme_confirm" != "YES-USE-THIS-DISK" ]]; then
          warn "Selection cancelled. Please choose again."
          continue
        fi
      fi
      TARGET_INPUT="$selected"
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
  --version                  Print script version and exit
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
      if [[ $# -lt 2 ]]; then
        err "--image requires a value (e.g. --image dockurr/umbrel)"
        exit 1
      fi
      IMAGE="$2"
      shift
      ;;
    --data-dir)
      if [[ $# -lt 2 ]]; then
        err "--data-dir requires a value (e.g. --data-dir /mnt/fullnode)"
        exit 1
      fi
      DATA_DIR="$2"
      shift
      ;;
    --target-partition)
      if [[ $# -lt 2 ]]; then
        err "--target-partition requires a value (e.g. --target-partition /dev/nvme0n1)"
        exit 1
      fi
      TARGET_PARTITION="$2"
      shift
      ;;
    --remove-tailscale)
      RELEASE_MODE=1
      PRESERVE_TAILSCALE=0
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

for required_cmd in python3 curl blkid mkfs.ext4 lsblk findmnt; do
  if ! command -v "$required_cmd" >/dev/null 2>&1; then
    err "Required command '$required_cmd' is not installed."
    exit 1
  fi
done

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

if [[ -z "$ROOT_DISK" ]]; then
  warn "Could not determine the current root/system disk automatically."
  if [[ -n "$TARGET_INPUT" ]]; then
    warn "Root disk detection failed. Proceeding with explicit target: $TARGET_INPUT"
    warn "Please verify this is NOT your system disk."
    if [[ "$DRY_RUN" -eq 0 ]]; then
      read -r -p "Type CONFIRM-TARGET to continue anyway: " ROOT_CONFIRM
      if [[ "$ROOT_CONFIRM" != "CONFIRM-TARGET" ]]; then
        err "Aborted by user."
        exit 1
      fi
    fi
  fi
fi

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

# Make sure unattended-upgrades or any other apt consumer is not holding the
# dpkg lock. If we continue while the lock is held, the Docker install step
# (which shells out to `apt-get`) will fail midway.
wait_for_apt_locks

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
  if [[ -n "${SUDO_USER:-}" && "$user" == "$SUDO_USER" ]]; then
    warn "Skipping removal of '$user': this is the current sudo user."
    continue
  fi
  if user_exists "$user"; then
    run_cmd userdel -r "$user" || warn "Failed to remove user '$user' (continuing)"
  fi
done

info "Backing up /etc/fstab before modification"
run_cmd cp /etc/fstab "/etc/fstab.bak.$(date +%s)"

info "Cleaning fstab entries that belong to RaspiBlitz eMMC setup"
TARGET_SWAP_PATHS_STR="${TARGET_SWAP_PATHS[*]}"
TARGET_MOUNT_PATHS_STR="${TARGET_MOUNT_PATHS[*]}"
TARGET_EXISTING_PARTITIONS_STR="${TARGET_EXISTING_PARTITIONS[*]}"
run_shell "TARGET_MOUNT_PATHS_STR=${TARGET_MOUNT_PATHS_STR@Q} DATA_DIR_VALUE=${DATA_DIR@Q} TARGET_SWAP_PATHS_STR=${TARGET_SWAP_PATHS_STR@Q} TARGET_EXISTING_PARTITIONS_STR=${TARGET_EXISTING_PARTITIONS_STR@Q} python3 - <<'PY'
from pathlib import Path
import os, tempfile
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
    fd, tmp = tempfile.mkstemp(dir='/etc', prefix='fstab.tmp.')
    os.write(fd, new.encode())
    os.fsync(fd)
    os.close(fd)
    os.chmod(tmp, 0o644)
    os.rename(tmp, str(fstab))
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

run_shell "FSTAB_UUID=${TARGET_UUID@Q} FSTAB_MOUNT=${DATA_DIR@Q} python3 - <<'PY'
from pathlib import Path
import os, tempfile
fstab = Path('/etc/fstab')
uuid_val = os.environ['FSTAB_UUID']
mount_val = os.environ['FSTAB_MOUNT']
entry = 'UUID={}\t{}\text4\tdefaults,auto,exec,rw\t0\t0'.format(uuid_val, mount_val)
text = fstab.read_text()
lines = text.splitlines()
# Remove any existing entries for the same UUID or mountpoint to prevent duplicates
filtered = []
for line in lines:
    stripped = line.strip()
    if not stripped or stripped.startswith('#'):
        filtered.append(line)
        continue
    parts = stripped.split()
    if len(parts) >= 2:
        source, mountpoint = parts[0], parts[1]
        if source == 'UUID={}'.format(uuid_val):
            continue
        if mountpoint == mount_val:
            continue
    filtered.append(line)
filtered.append(entry)
new = '\n'.join(filtered) + '\n'
fd, tmp = tempfile.mkstemp(dir='/etc', prefix='fstab.tmp.')
os.write(fd, new.encode())
os.fsync(fd)
os.close(fd)
os.chmod(tmp, 0o644)
os.rename(tmp, str(fstab))
PY"

CURRENT_DATA_SOURCE="$(findmnt -n -o SOURCE --target "$DATA_DIR" 2>/dev/null || true)"
if [[ "$DRY_RUN" -eq 0 && "$CURRENT_DATA_SOURCE" != "$TARGET_PARTITION" ]]; then
  err "Mount verification failed. Expected $TARGET_PARTITION at $DATA_DIR, got ${CURRENT_DATA_SOURCE:-NOT_MOUNTED}."
  exit 1
fi

info "Configuring conservative NVMe power policy for future boots"
FLASH_KERNEL_DEFAULTS="/etc/default/flash-kernel"
if [[ "$DRY_RUN" -eq 1 ]]; then
  echo "[DRY-RUN] backup $FLASH_KERNEL_DEFAULTS"
  echo "[DRY-RUN] append nvme_core.default_ps_max_latency_us=0 pcie_aspm=off pcie_port_pm=off to LINUX_KERNEL_CMDLINE"
  echo "[DRY-RUN] flash-kernel"
elif [[ -f "$FLASH_KERNEL_DEFAULTS" ]]; then
  run_cmd cp "$FLASH_KERNEL_DEFAULTS" "$FLASH_KERNEL_DEFAULTS.bak.$(date +%s)"
  run_shell "FLASH_KERNEL_FILE=${FLASH_KERNEL_DEFAULTS@Q} python3 - <<'PY'
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
        prefix = 'LINUX_KERNEL_CMDLINE=\"'
        if line.startswith(prefix) and line.endswith('\"'):
            body = line[len(prefix):-1]
        else:
            body = line.split('=', 1)[1].strip().strip('\"')
        parts = body.split()
        for needle in needles:
            if needle not in parts:
                parts.append(needle)
        line = prefix + ' '.join(parts) + '\"'
    out.append(line)
if not found:
    out.append('LINUX_KERNEL_CMDLINE="' + needle + '"')
path.write_text('\n'.join(out) + '\n')
PY"
  if command -v flash-kernel >/dev/null 2>&1; then
    run_cmd flash-kernel
  else
    warn "flash-kernel not found. APST-off kernel parameter was recorded but boot script was not regenerated."
  fi
else
  warn "$FLASH_KERNEL_DEFAULTS not found. Skipping APST-off kernel parameter setup."
fi

info "Installing fresh Docker"
if [[ "$DRY_RUN" -eq 0 ]]; then
  if ! curl -fsSL https://get.docker.com | sh; then
    err "Docker installation failed."
    err "The SSD has already been formatted and mounted at $DATA_DIR."
    err "To retry Docker installation only, run:"
    err "  curl -fsSL https://get.docker.com | sudo sh"
    err "Then start Umbrel manually:"
    err "  sudo docker run -d --name umbrel --restart always -p 80:80 -v $DATA_DIR:/data -v /var/run/docker.sock:/var/run/docker.sock --stop-timeout 60 --privileged $IMAGE"
    exit 1
  fi
else
  run_shell 'curl -fsSL https://get.docker.com | sh'
fi

info "Installing self-heal guard for fullnode mount"
DOCKER_DROPIN_DIR="/etc/systemd/system/docker.service.d"
DOCKER_DROPIN_FILE="$DOCKER_DROPIN_DIR/require-fullnode.conf"
GUARD_SCRIPT="/usr/local/sbin/fullnode-mount-guard.sh"
GUARD_SERVICE="/etc/systemd/system/fullnode-mount-guard.service"
GUARD_TIMER="/etc/systemd/system/fullnode-mount-guard.timer"
if [[ "$DRY_RUN" -eq 1 ]]; then
  echo "[DRY-RUN] create $DOCKER_DROPIN_FILE"
  echo "[DRY-RUN] create $GUARD_SCRIPT"
  echo "[DRY-RUN] create $GUARD_SERVICE"
  echo "[DRY-RUN] create $GUARD_TIMER"
  echo "[DRY-RUN] systemctl daemon-reload"
  echo "[DRY-RUN] systemctl enable --now fullnode-mount-guard.timer"
else
  run_cmd mkdir -p "$DOCKER_DROPIN_DIR"
  cat > "$DOCKER_DROPIN_FILE" <<EOF
[Unit]
RequiresMountsFor=$DATA_DIR
EOF
  cat > "$GUARD_SCRIPT" <<EOF
#!/bin/bash
set -euo pipefail
MOUNTPOINT="$DATA_DIR"
EXPECTED_SOURCE="$TARGET_PARTITION"
STATE_DIR="/var/lib/fullnode-mount-guard"
REBOOT_FLAG="\$STATE_DIR/reboot-attempted"
SNAPSHOT_DIR="\$STATE_DIR/snapshots"
mkdir -p "\$STATE_DIR"
mkdir -p "\$SNAPSHOT_DIR"

log() {
  logger -t fullnode-mount-guard "\$1"
}

capture_snapshot() {
  local reason="\$1"
  local ts snapshot
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
  lspci -vv -s 01:00.0 > "\$snapshot/lspci-01_00_0.txt" 2>&1 || true
  smartctl -a /dev/nvme0 > "\$snapshot/smartctl.txt" 2>&1 || true
  nvme smart-log /dev/nvme0 > "\$snapshot/nvme-smart-log.txt" 2>&1 || true
}

stop_docker() {
  systemctl stop docker.service docker.socket >/dev/null 2>&1 || true
}

start_docker() {
  systemctl start docker.socket docker.service >/dev/null 2>&1 || true
}

clear_reboot_flag() {
  rm -f "\$REBOOT_FLAG"
}

current_source() {
  findmnt -n -o SOURCE --target "\$MOUNTPOINT" 2>/dev/null || true
}

mount_is_healthy() {
  mountpoint -q "\$MOUNTPOINT" && [ "\$(current_source)" = "\$EXPECTED_SOURCE" ]
}

recover_mount() {
  if [ ! -b "\$EXPECTED_SOURCE" ]; then
    return 1
  fi
  if mountpoint -q "\$MOUNTPOINT"; then
    umount "\$MOUNTPOINT" >/dev/null 2>&1 || true
  fi
  mount "\$MOUNTPOINT" >/dev/null 2>&1 || true
  sleep 2
  mount_is_healthy
}

if mount_is_healthy; then
  clear_reboot_flag
  exit 0
fi

if mountpoint -q "\$MOUNTPOINT"; then
  log "\$MOUNTPOINT source is \$(current_source); expected \$EXPECTED_SOURCE; stopping docker and attempting remount"
  capture_snapshot wrong-source
else
  log "\$MOUNTPOINT is not mounted; stopping docker and attempting recovery"
  capture_snapshot not-mounted
fi

stop_docker

if recover_mount; then
  log "Recovered \$MOUNTPOINT with \$EXPECTED_SOURCE; restarting docker"
  clear_reboot_flag
  start_docker
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
  run_cmd chmod 0755 "$GUARD_SCRIPT"
  cat > "$GUARD_SERVICE" <<EOF
[Unit]
Description=Auto-heal fullnode mount and protect Docker
After=local-fs.target

[Service]
Type=oneshot
ExecStart=$GUARD_SCRIPT
EOF
  cat > "$GUARD_TIMER" <<EOF
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
  run_cmd systemctl daemon-reload
  run_cmd systemctl enable --now fullnode-mount-guard.timer
fi

run_cmd systemctl enable docker
run_cmd systemctl start docker

if [[ -n "${SUDO_USER:-}" && "${SUDO_USER}" != "root" ]]; then
  run_cmd usermod -aG docker "$SUDO_USER"
fi

info "Pulling and starting Umbrel"
run_cmd docker pull "$IMAGE"
run_shell "docker rm -f umbrel >/dev/null 2>&1 || true"
# Note: --privileged and docker.sock mount are required by the dockurr/umbrel image
# to manage its internal Docker containers. --pid=host is required for process management.
run_cmd docker run -d --name umbrel --restart always -p 80:80 -v "$DATA_DIR:/data" -v /var/run/docker.sock:/var/run/docker.sock --stop-timeout 60 --pid=host --privileged "$IMAGE"

if [[ "$DRY_RUN" -eq 0 ]]; then
  info "Waiting for Umbrel container to stabilize..."
  sleep 10
  CONTAINER_STATE="$(docker inspect --format='{{.State.Status}}' umbrel 2>/dev/null || true)"
  if [[ "$CONTAINER_STATE" != "running" ]]; then
    warn "Umbrel container is not running (state: ${CONTAINER_STATE:-unknown})."
    warn "Check logs with: docker logs umbrel"
    warn "The SSD is mounted at $DATA_DIR and Docker is installed. You can retry:"
    warn "  docker rm -f umbrel; docker run -d --name umbrel --restart always -p 80:80 -v $DATA_DIR:/data -v /var/run/docker.sock:/var/run/docker.sock --stop-timeout 60 --pid=host --privileged $IMAGE"
  else
    info "Umbrel container is running."
  fi
fi

info "Setting up umbrel.local mDNS alias"
if ! command -v avahi-publish >/dev/null 2>&1; then
  info "Installing avahi-daemon and avahi-utils..."
  if [[ "$DRY_RUN" -eq 0 ]]; then
    DEBIAN_FRONTEND=noninteractive apt-get install -y avahi-daemon avahi-utils libnss-mdns >/dev/null 2>&1 || true
  else
    run_shell 'DEBIAN_FRONTEND=noninteractive apt-get install -y avahi-daemon avahi-utils libnss-mdns'
  fi
fi

# Restrict avahi-daemon to eth0 so Docker veth interfaces do not pollute
# mDNS responses (umbrel.local must not resolve to a veth IPv6 address).
AVAHI_CONF="/etc/avahi/avahi-daemon.conf"
if [[ "$DRY_RUN" -eq 1 ]]; then
  echo "[DRY-RUN] set allow-interfaces=eth0 in $AVAHI_CONF"
  echo "[DRY-RUN] systemctl restart avahi-daemon"
elif [[ -f "$AVAHI_CONF" ]]; then
  if ! grep -qE '^allow-interfaces=' "$AVAHI_CONF"; then
    cp "$AVAHI_CONF" "$AVAHI_CONF.bak.$(date +%s)"
    sed -i 's/^#allow-interfaces=.*/allow-interfaces=eth0/' "$AVAHI_CONF"
    if ! grep -qE '^allow-interfaces=' "$AVAHI_CONF"; then
      # Fallback: template did not have a commented line. Append to [server].
      python3 - "$AVAHI_CONF" <<'PY'
import sys, re
from pathlib import Path
p = Path(sys.argv[1])
text = p.read_text()
if re.search(r'^allow-interfaces=', text, flags=re.M):
    sys.exit(0)
# Insert after [server]
text = re.sub(r'(\[server\]\n)', r'\1allow-interfaces=eth0\n', text, count=1)
p.write_text(text)
PY
    fi
    systemctl restart avahi-daemon || warn "Failed to restart avahi-daemon (continuing)"
    info "avahi-daemon restricted to eth0"
  else
    info "avahi-daemon allow-interfaces already set; leaving as is"
  fi
fi

AVAHI_ALIAS_SCRIPT="/usr/local/bin/avahi-publish-umbrel"
AVAHI_ALIAS_SERVICE="/etc/systemd/system/avahi-alias-umbrel.service"

if [[ "$DRY_RUN" -eq 1 ]]; then
  echo "[DRY-RUN] write $AVAHI_ALIAS_SCRIPT"
  echo "[DRY-RUN] write $AVAHI_ALIAS_SERVICE"
  echo "[DRY-RUN] systemctl enable --now avahi-alias-umbrel.service"
else
  cat > "$AVAHI_ALIAS_SCRIPT" <<'ALIASSCRIPT'
#!/usr/bin/env bash
set -eu
while true; do
  IP="$(ip -4 addr show scope global | awk '/inet / {print $2}' | cut -d/ -f1 | head -n1)"
  if [[ -n "$IP" ]]; then
    avahi-publish-address -R umbrel.local "$IP"
  fi
  sleep 5
done
ALIASSCRIPT
  chmod +x "$AVAHI_ALIAS_SCRIPT"

  cat > "$AVAHI_ALIAS_SERVICE" <<'SERVICEUNIT'
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
  systemctl enable avahi-alias-umbrel.service
  systemctl start avahi-alias-umbrel.service
  info "umbrel.local mDNS alias is now active."
fi

info "Recording install state"
if [[ "$DRY_RUN" -eq 1 ]]; then
  echo "[DRY-RUN] write $INSTALL_STATE_FILE (version=$SCRIPT_VERSION)"
else
  mkdir -p "$INSTALL_STATE_DIR"
  INSTALL_TIMESTAMP="$(date -Is)"
  python3 - "$INSTALL_STATE_FILE" "$SCRIPT_VERSION" "$INSTALL_TIMESTAMP" "$IMAGE" "$DATA_DIR" "$TARGET_PARTITION" <<'PY'
import json, os, sys, tempfile
path, version, ts, image, data_dir, target = sys.argv[1:7]
payload = {
    "version": version,
    "installed_at": ts,
    "installed_by": "m1s-clean-install-umbrel.sh",
    "image": image,
    "data_dir": data_dir,
    "target_partition": target,
}
d = os.path.dirname(path)
fd, tmp = tempfile.mkstemp(dir=d, prefix="installed.tmp.")
with os.fdopen(fd, "w") as f:
    json.dump(payload, f, indent=2)
    f.write("\n")
os.chmod(tmp, 0o644)
os.rename(tmp, path)
PY
  info "Install state written to $INSTALL_STATE_FILE (version=$SCRIPT_VERSION)"
fi

info "Done."
cat <<EOF

Umbrel container has been started.
Open: http://umbrel.local  or  http://<device-ip>
Image: $IMAGE
Data directory: $DATA_DIR
Script version: $SCRIPT_VERSION

If you used --dry-run, no changes were made.
If Docker group membership was updated for your user, log out and back in before using docker without sudo.
EOF
