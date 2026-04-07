#!/usr/bin/env bash
set -Eeuo pipefail

DRY_RUN=0
RELEASE_MODE=0
IMAGE="dockurr/umbrel"
DATA_DIR="/mnt/fullnode"
PRESERVE_TAILSCALE=1
TARGET_PARTITION="/dev/nvme0n1p1"
EXISTING_TARGET_MOUNT=""
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
  --target-partition PATH    SSD partition to format and mount (default: /dev/nvme0n1p1)
  --remove-tailscale         Alias for --release
  -h, --help                 Show this help

Examples:
  sudo bash m1s-clean-install-umbrel.sh --dry-run
  sudo bash m1s-clean-install-umbrel.sh --data-dir /mnt/fullnode
  sudo bash m1s-clean-install-umbrel.sh --image tao9317/tao-umbrel --data-dir /mnt/fullnode
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
TARGET_DISK="$(lsblk -no PKNAME "$TARGET_PARTITION" 2>/dev/null | head -n1 || true)"
CURRENT_DATA_SOURCE="$(findmnt -n -o SOURCE --target "$DATA_DIR" 2>/dev/null || true)"
EXISTING_TARGET_MOUNT="$(findmnt -rn -S "$TARGET_PARTITION" -o TARGET 2>/dev/null | head -n1 || true)"

while IFS= read -r swap_path; do
  [[ -z "$swap_path" ]] && continue
  TARGET_SWAP_PATHS+=("$swap_path")
done < <(swapon --noheadings --raw --output=NAME 2>/dev/null | while read -r p; do
  [[ -n "$p" ]] || continue
  if [[ "$p" == "$TARGET_PARTITION" ]]; then
    printf '%s\n' "$p"
  elif [[ -n "$EXISTING_TARGET_MOUNT" && "$p" == "$EXISTING_TARGET_MOUNT"* ]]; then
    printf '%s\n' "$p"
  fi
done)

if [[ ! -b "$TARGET_PARTITION" ]]; then
  err "Target partition does not exist: $TARGET_PARTITION"
  exit 1
fi

if [[ -z "$TARGET_DISK" ]]; then
  err "Could not determine parent disk for target partition: $TARGET_PARTITION"
  exit 1
fi

if [[ -n "$ROOT_DISK" && "$TARGET_DISK" == "$ROOT_DISK" ]]; then
  err "Refusing to format the root/system disk. Root disk: /dev/$ROOT_DISK, target: $TARGET_PARTITION"
  exit 1
fi

if [[ "$TARGET_DISK" != nvme* ]]; then
  warn "Target partition parent disk is /dev/$TARGET_DISK, not an nvme device."
fi

cat <<EOF

=== ODROID M1S Cleanup + Umbrel Installer ===
Model:              $MODEL
OS:                 Ubuntu ${VERSION_ID}
Architecture:       $ARCH
Root filesystem:    ${ROOT_SOURCE:-unknown}
Umbrel image:       $IMAGE
Umbrel data dir:    $DATA_DIR
Target partition:   $TARGET_PARTITION
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

This script WILL erase all existing data on $TARGET_PARTITION.
EOF

if [[ "$DRY_RUN" -eq 0 ]]; then
  echo
  warn "This is destructive for services and files stored on eMMC."
  warn "This will also format $TARGET_PARTITION and erase all existing SSD data on that partition."
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
run_shell "EXISTING_MOUNT=${EXISTING_TARGET_MOUNT@Q} DATA_DIR_VALUE=${DATA_DIR@Q} TARGET_SWAP_PATHS_STR=${TARGET_SWAP_PATHS_STR@Q} python3 - <<'PY'
from pathlib import Path
import os
fstab = Path('/etc/fstab')
text = fstab.read_text()
lines = text.splitlines()
filtered = []
existing_mount = os.environ.get('EXISTING_MOUNT', '')
data_dir = os.environ.get('DATA_DIR_VALUE', '')
target_swaps = [p for p in os.environ.get('TARGET_SWAP_PATHS_STR', '').split() if p]
for line in lines:
    stripped = line.strip()
    if '/var/cache/raspiblitz' in stripped:
        continue
    if existing_mount and existing_mount in stripped:
        continue
    if data_dir and data_dir in stripped:
        continue
    if any(swap_path in stripped for swap_path in target_swaps):
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
  if [[ -n "$EXISTING_TARGET_MOUNT" ]]; then
    run_shell "fuser -vm '$EXISTING_TARGET_MOUNT' || true"
  fi
fi
if [[ "$DRY_RUN" -eq 1 ]]; then
  for swap_path in "${TARGET_SWAP_PATHS[@]}"; do
    run_shell "swapoff '$swap_path' >/dev/null 2>&1 || true"
  done
  if [[ -n "$EXISTING_TARGET_MOUNT" ]]; then
    run_shell "umount '$EXISTING_TARGET_MOUNT' >/dev/null 2>&1 || true"
  fi
  run_shell "umount '$TARGET_PARTITION' >/dev/null 2>&1 || true"
  run_shell "umount '$DATA_DIR' >/dev/null 2>&1 || true"
else
  for swap_path in "${TARGET_SWAP_PATHS[@]}"; do
    bash -lc "swapoff '$swap_path' >/dev/null 2>&1 || true"
  done
  if [[ -n "$EXISTING_TARGET_MOUNT" ]]; then
    bash -lc "umount '$EXISTING_TARGET_MOUNT' >/dev/null 2>&1 || true"
  fi
  bash -lc "umount '$TARGET_PARTITION' >/dev/null 2>&1 || true"
  bash -lc "umount '$DATA_DIR' >/dev/null 2>&1 || true"

  if findmnt -rn -S "$TARGET_PARTITION" >/dev/null 2>&1; then
    err "Target partition is still mounted after unmount attempt: $TARGET_PARTITION"
    err "Stop remaining processes using the SSD and try again."
    exit 1
  fi

  CURRENT_DATA_SOURCE="$(findmnt -rn -o SOURCE -T "$DATA_DIR" 2>/dev/null || true)"
  if [[ -n "$CURRENT_DATA_SOURCE" && "$CURRENT_DATA_SOURCE" != "$ROOT_SOURCE" && "$CURRENT_DATA_SOURCE" != "tmpfs" ]]; then
    err "Data directory is still backed by a non-root mounted filesystem after unmount attempt: $DATA_DIR -> $CURRENT_DATA_SOURCE"
    err "Stop remaining processes using the SSD and try again."
    exit 1
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
