#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_VERSION="0.5.30"
INSTALL_STATE_VERSION="0.5.30"
INSTALL_STATE_DIR="/etc/umbrel-recovery"
INSTALL_STATE_FILE="$INSTALL_STATE_DIR/installed.json"
PREINSTALL_RESUME_STATE_FILE="$INSTALL_STATE_DIR/preinstall-resume.json"
PREINSTALL_RESUME_SERVICE="/etc/systemd/system/m1s-preinstall-resume.service"
SAFE_SHUTDOWN_SERVICE="/etc/systemd/system/m1s-umbrel-autostart.service"

DRY_RUN=0
RELEASE_MODE=0
AUTO_RESUME_INSTALL="${AUTO_RESUME_INSTALL:-0}"
IMAGE="dockurr/umbrel:1.7.4@sha256:e00c07a838ce3b50641a0a984abe155a7223abacab3426a55409edf21b6e0124"
RESOLVED_UMBREL_IMAGE_ID=""
RESOLVED_UMBREL_IMAGE_ARCHITECTURE=""
EXPECTED_TOR_PROXY_IMAGE="ghcr.io/getumbrel/tor:0.4.9.11"
CANONICAL_AUTH_CONTAINER="umbrel_auth"
CANONICAL_TOR_PROXY_CONTAINER="umbrel_tor_proxy"
UMBREL_RUNTIME_HEALTH_ATTEMPTS="${UMBREL_RUNTIME_HEALTH_ATTEMPTS:-30}"
UMBREL_RUNTIME_HEALTH_DELAY="${UMBREL_RUNTIME_HEALTH_DELAY:-2}"
DATA_DIR="/mnt/fullnode"
HOST_DATA_ALIAS="/data"
DATA_ALIAS_FSTAB_OPTIONS="bind,nofail,x-systemd.requires-mounts-for=$DATA_DIR"
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
DESTRUCTIVE_WINDOW_MASKED_UNITS=()
DESTRUCTIVE_WINDOW_ACTIVE=0
PRESERVED_PATHS=(
  /var/lib/fullnode-mount-guard
  /usr/local/sbin/fullnode-mount-guard.sh
  /etc/systemd/system/fullnode-mount-guard.service
  /etc/systemd/system/fullnode-mount-guard.timer
  /etc/systemd/system/docker.service.d/require-fullnode.conf
  /var/lib/nvme-timeout-snapshot
  /usr/local/sbin/nvme-timeout-snapshot.sh
  /etc/systemd/system/nvme-timeout-snapshot.service
  /etc/systemd/system/nvme-timeout-snapshot.timer
  /etc/systemd/system/m1s-umbrel-autostart.service
)
APT_LOCK_FILES=(/var/lib/dpkg/lock-frontend /var/lib/dpkg/lock /var/lib/apt/lists/lock)
APT_AUTOMATION_UNITS=(
  apt-daily.timer
  apt-daily-upgrade.timer
  apt-daily.service
  apt-daily-upgrade.service
  unattended-upgrades.service
)
APT_AUTOMATION_RESTORE_UNITS=()
APT_AUTOMATION_PAUSED=0
ORIGINAL_ARGS=("$@")
SCRIPT_PATH_ABS=""

# shellcheck source=scripts/m1s-support-policy.sh
source "$(dirname "${BASH_SOURCE[0]}")/m1s-support-policy.sh"
# shellcheck source=scripts/m1s-backup-retention.sh
source "$(dirname "${BASH_SOURCE[0]}")/m1s-backup-retention.sh"
# shellcheck source=scripts/m1s-avahi-mdns.sh
source "$(dirname "${BASH_SOURCE[0]}")/m1s-avahi-mdns.sh"

log() {
  printf '[%s] %s\n' "$1" "$2"
}

info() { log INFO "$1"; }
warn() { log WARN "$1"; }
err() { log ERROR "$1" >&2; }

abort_by_user() {
  err "Aborted by user."
  exit 130
}

trap abort_by_user INT

is_abort_input() {
  local value="${1:-}"
  local interrupt_char
  interrupt_char="$(printf '\003')"
  [[ "$value" == "$interrupt_char" || "$value" == "q" || "$value" == "Q" || "$value" == "quit" || "$value" == "exit" ]]
}

read_prompt_or_abort() {
  local target_var="$1"
  local prompt="$2"
  local value=""

  if ! IFS= read -r -p "$prompt" value; then
    abort_by_user
  fi

  if is_abort_input "$value"; then
    abort_by_user
  fi

  printf -v "$target_var" '%s' "$value"
}

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
  local locks=("${APT_LOCK_FILES[@]}")
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
  err "The most common cause is Ubuntu automatic updates still running."
  err "Wait for the update to finish, then rerun this installer."
  err "Do not delete apt/dpkg lock files or kill package-manager processes just to bypass this wait."
  err "If this repeats, keep a photo or copy of this output and ask for help."
  exit 1
}

systemd_unit_exists() {
  local unit="$1"
  systemctl list-unit-files "$unit" --no-legend >/dev/null 2>&1 || systemctl status "$unit" >/dev/null 2>&1
}

pause_apt_automation() {
  if [[ "$APT_AUTOMATION_PAUSED" -eq 1 ]]; then
    return 0
  fi
  APT_AUTOMATION_PAUSED=1

  if [[ "$DRY_RUN" -eq 1 ]]; then
    echo "[DRY-RUN] temporarily stop apt automation units during installer apt operations"
    return 0
  fi
  command -v systemctl >/dev/null 2>&1 || return 0

  local unit
  APT_AUTOMATION_RESTORE_UNITS=()
  for unit in "${APT_AUTOMATION_UNITS[@]}"; do
    systemd_unit_exists "$unit" || continue
    if systemctl is-active --quiet "$unit"; then
      APT_AUTOMATION_RESTORE_UNITS+=("$unit")
    fi
  done

  for unit in "${APT_AUTOMATION_UNITS[@]}"; do
    systemd_unit_exists "$unit" || continue
    systemctl stop "$unit" >/dev/null 2>&1 || true
  done
}

resume_apt_automation() {
  [[ "$APT_AUTOMATION_PAUSED" -eq 1 ]] || return 0
  APT_AUTOMATION_PAUSED=0

  if [[ "$DRY_RUN" -eq 1 ]]; then
    echo "[DRY-RUN] restore apt automation units that were active before installer apt operations"
    return 0
  fi
  command -v systemctl >/dev/null 2>&1 || return 0

  local unit
  for unit in "${APT_AUTOMATION_RESTORE_UNITS[@]}"; do
    systemd_unit_exists "$unit" || continue
    systemctl start "$unit" >/dev/null 2>&1 || warn "Failed to restore apt automation unit: $unit"
  done
  APT_AUTOMATION_RESTORE_UNITS=()
}

cleanup_on_exit() {
  local exit_code=$?
  trap - EXIT

  if [[ "$DESTRUCTIVE_WINDOW_ACTIVE" -eq 1 ]]; then
    if [[ "$exit_code" -ne 0 && "$DRY_RUN" -eq 0 ]]; then
      err "Docker was deliberately left stopped so Umbrel data cannot be written to the eMMC root filesystem instead of the SSD."
      err "Check /mnt/fullnode, then reboot or rerun the installer."
    fi
    if ! leave_destructive_storage_window; then
      warn "Failed to remove one or more runtime masks; reboot before retrying the installer."
    fi
  fi

  resume_apt_automation || true
  return "$exit_code"
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

collect_target_busy_pids() {
  command -v fuser >/dev/null 2>&1 || return 0

  local paths=()
  local path raw pid
  for path in "${TARGET_MOUNT_PATHS[@]}" "${TARGET_EXISTING_PARTITIONS[@]}" "$TARGET_DISK_PATH" "$TARGET_PARTITION" "$HOST_DATA_ALIAS" "$DATA_DIR"; do
    [[ -n "$path" ]] || continue
    if append_unique "$path" "${paths[@]}"; then
      paths+=("$path")
    fi
  done

  local seen=()
  for path in "${paths[@]}"; do
    raw="$(fuser "$path" 2>/dev/null || true)"
    for pid in $raw; do
      [[ "$pid" =~ ^[0-9]+$ ]] || continue
      if append_unique "$pid" "${seen[@]}"; then
        seen+=("$pid")
        printf '%s\n' "$pid"
      fi
    done
  done
}

is_installer_process_ancestor() {
  local candidate="$1"
  local current="$BASHPID"
  local parent

  while [[ -n "$current" && "$current" =~ ^[0-9]+$ && "$current" != "0" ]]; do
    [[ "$candidate" == "$current" ]] && return 0
    parent="$(ps -p "$current" -o ppid= 2>/dev/null | xargs || true)"
    [[ -n "$parent" && "$parent" != "$current" ]] || break
    current="$parent"
  done

  return 1
}

describe_pid() {
  local pid="$1"
  local args
  args="$(ps -p "$pid" -o args= 2>/dev/null | xargs || true)"
  [[ -n "$args" ]] || args="unknown"
  printf '%s' "$args"
}

is_protected_busy_pid() {
  local pid="$1"
  [[ "$pid" =~ ^[0-9]+$ ]] || return 0
  [[ "$pid" == "1" ]] && return 0
  is_installer_process_ancestor "$pid" && return 0

  local comm args
  comm="$(ps -p "$pid" -o comm= 2>/dev/null | xargs || true)"
  args="$(ps -p "$pid" -o args= 2>/dev/null | xargs || true)"

  case "$comm" in
    systemd|sshd|ssh|sudo|systemd-networkd|NetworkManager|systemd-resolved|dbus-daemon|systemd-udevd|udevd|cron|apt|apt-get|dpkg|dpkg-deb|unattended-upgr)
      return 0
      ;;
  esac

  if [[ -n "$SCRIPT_PATH_ABS" && "$args" == *"$SCRIPT_PATH_ABS"* ]]; then
    return 0
  fi
  [[ "$args" == *"m1s-clean-install-umbrel.sh"* ]] && return 0

  return 1
}

filter_killable_target_pids() {
  local pid
  for pid in "$@"; do
    [[ -n "$pid" ]] || continue
    if is_protected_busy_pid "$pid"; then
      warn "Preserving protected SSD holder PID $pid: $(describe_pid "$pid")" >&2
      continue
    fi
    printf '%s\n' "$pid"
  done
}

stop_target_busy_processes() {
  command -v fuser >/dev/null 2>&1 || return 0

  local pids=()
  local killable=()
  local survivors=()
  local pid
  mapfile -t pids < <(collect_target_busy_pids)
  [[ "${#pids[@]}" -gt 0 ]] || return 0

  mapfile -t killable < <(filter_killable_target_pids "${pids[@]}")
  [[ "${#killable[@]}" -gt 0 ]] || return 0

  warn "The selected NVMe SSD is still being used by old processes. Stopping only processes that hold the selected SSD."
  for pid in "${killable[@]}"; do
    warn "Sending SIGTERM to SSD holder PID $pid: $(describe_pid "$pid")"
    if [[ "$DRY_RUN" -eq 1 ]]; then
      printf '[DRY-RUN] kill -TERM %q\n' "$pid"
    else
      kill -TERM "$pid" 2>/dev/null || true
    fi
  done

  if [[ "$DRY_RUN" -eq 1 ]]; then
    echo "[DRY-RUN] sleep 3"
  else
    sleep 3
  fi

  mapfile -t pids < <(collect_target_busy_pids)
  mapfile -t survivors < <(filter_killable_target_pids "${pids[@]}")
  [[ "${#survivors[@]}" -gt 0 ]] || return 0

  for pid in "${survivors[@]}"; do
    warn "Sending SIGKILL to stubborn SSD holder PID $pid: $(describe_pid "$pid")"
    if [[ "$DRY_RUN" -eq 1 ]]; then
      printf '[DRY-RUN] kill -KILL %q\n' "$pid"
    else
      kill -KILL "$pid" 2>/dev/null || true
    fi
  done

  if [[ "$DRY_RUN" -eq 1 ]]; then
    echo "[DRY-RUN] sleep 1"
  else
    sleep 1
  fi
}

enter_destructive_storage_window() {
  local units=(
    docker.service
    docker.socket
    fullnode-mount-guard.timer
    fullnode-mount-guard.service
    m1s-umbrel-autostart.service
  )
  local unit
  local mask_failed=0

  info "Holding down remount-capable units for the destructive storage window"
  DESTRUCTIVE_WINDOW_MASKED_UNITS=()
  DESTRUCTIVE_WINDOW_ACTIVE=1
  for unit in "${units[@]}"; do
    systemctl cat "$unit" >/dev/null 2>&1 || continue
    if run_cmd systemctl mask --runtime "$unit"; then
      DESTRUCTIVE_WINDOW_MASKED_UNITS+=("$unit")
    else
      err "Failed to apply runtime mask for destructive storage window unit: $unit"
      mask_failed=1
    fi
  done

  run_cmd systemctl stop "${units[@]}" || true
  [[ "$mask_failed" -eq 0 ]]
}

leave_destructive_storage_window() {
  local unit
  local unmask_failed=0

  [[ "$DESTRUCTIVE_WINDOW_ACTIVE" -eq 1 ]] || return 0
  for unit in "${DESTRUCTIVE_WINDOW_MASKED_UNITS[@]}"; do
    if ! run_cmd systemctl unmask --runtime "$unit"; then
      err "Failed to remove runtime mask from destructive storage window unit: $unit"
      unmask_failed=1
    fi
  done

  [[ "$unmask_failed" -eq 0 ]] || return 1
  DESTRUCTIVE_WINDOW_MASKED_UNITS=()
  DESTRUCTIVE_WINDOW_ACTIVE=0
}

assert_raw_disk_exclusive() {
  local disk_path="$1"
  local probe_status=0

  if [[ "$DRY_RUN" -eq 1 ]]; then
    printf '[DRY-RUN] verify exclusive open O_RDONLY|O_EXCL|O_CLOEXEC for %q\n' "$disk_path"
    return 0
  fi

  if [[ -n "${M1S_EXCLUSIVE_PROBE_COMMAND:-}" ]]; then
    "$M1S_EXCLUSIVE_PROBE_COMMAND" "$disk_path" || probe_status=$?
  else
    python3 - "$disk_path" <<'PY' || probe_status=$?
import errno
import os
import sys

try:
    fd = os.open(sys.argv[1], os.O_RDONLY | os.O_EXCL | os.O_CLOEXEC)
except OSError as exc:
    if exc.errno == errno.EBUSY:
        raise SystemExit(75)
    raise
else:
    os.close(fd)
PY
  fi

  [[ "$probe_status" -eq 0 ]] && return 0
  if [[ "$probe_status" -eq 75 ]]; then
    err "Raw disk $disk_path was re-claimed after cleanup; refusing to repartition a device that is in use."
    info "Raw-disk exclusivity diagnostics"
    if command -v findmnt >/dev/null 2>&1; then
      findmnt -R /mnt/fullnode || true
      findmnt -R /data || true
      findmnt -S "$TARGET_PARTITION" || true
    fi
    if command -v swapon >/dev/null 2>&1; then
      swapon --show || true
    fi
    if command -v fuser >/dev/null 2>&1; then
      fuser -vm "$disk_path" "$TARGET_PARTITION" "$DATA_DIR" || true
    fi
    if command -v systemctl >/dev/null 2>&1; then
      systemctl is-active \
        docker.service \
        docker.socket \
        fullnode-mount-guard.timer \
        fullnode-mount-guard.service \
        m1s-umbrel-autostart.service \
        mnt-fullnode.mount \
        data.mount \
        mnt-fullnode-swapfile.swap || true
    fi
    exit 1
  fi

  err "Exclusive-open probe failed unexpectedly for raw disk $disk_path (exit status $probe_status)."
  exit 1
}

repartition_raw_disk() {
  info "Creating a fresh GPT partition on raw SSD $TARGET_DISK_PATH"
  info "Re-checking for stale SSD holders immediately before repartitioning the raw NVMe disk"
  stop_target_busy_processes
  if ! command -v sfdisk >/dev/null 2>&1; then
    err "sfdisk is required to create a partition on raw SSD targets, but it is not installed."
    exit 1
  fi
  assert_raw_disk_exclusive "$TARGET_DISK_PATH"
  if [[ "$DRY_RUN" -eq 1 ]]; then
    run_shell "printf ',,L\n' | sfdisk --label gpt '$TARGET_DISK_PATH'"
  else
    printf ',,L\n' | sfdisk --label gpt "$TARGET_DISK_PATH"
  fi
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

nvme_disk_visible() {
  lsblk -dn -o NAME,TYPE 2>/dev/null | awk '$2 == "disk" && $1 ~ /^nvme/ {found=1} END {exit found ? 0 : 1}'
}

target_input_looks_like_nvme() {
  local input="${1:-}"
  local parent=""
  local base=""
  [[ -n "$input" ]] || return 1
  parent="$(guess_parent_disk_path "$input")"
  if [[ -n "$parent" ]]; then
    base="$(basename "$parent")"
  else
    base="$(basename "$input")"
  fi
  [[ "$base" == nvme* ]]
}

detect_root_disk() {
  local source="${1:-}"
  local resolved=""
  local parent=""
  local disk=""
  local dev_type=""

  [[ -n "$source" ]] || return 0

  disk="$(lsblk -no PKNAME "$source" 2>/dev/null | head -n1 | xargs || true)"
  if [[ -n "$disk" ]]; then
    printf '%s\n' "$disk"
    return 0
  fi

  resolved="$(resolve_block_path "$source")"
  if [[ -n "$resolved" && "$resolved" != "$source" ]]; then
    disk="$(lsblk -no PKNAME "$resolved" 2>/dev/null | head -n1 | xargs || true)"
    if [[ -n "$disk" ]]; then
      printf '%s\n' "$disk"
      return 0
    fi
  fi

  for candidate in "$resolved" "$source"; do
    [[ -n "$candidate" ]] || continue
    parent="$(guess_parent_disk_path "$candidate")"
    if [[ -n "$parent" ]]; then
      printf '%s\n' "$(basename "$parent")"
      return 0
    fi
    if [[ "$candidate" == /dev/* ]]; then
      dev_type="$(lsblk -dn -o TYPE "$candidate" 2>/dev/null | head -n1 | xargs || true)"
      if [[ "$dev_type" == "disk" ]]; then
        printf '%s\n' "$(basename "$candidate")"
        return 0
      fi
    fi
  done
}

require_emmc_root_disk() {
  local root_disk="${1:-}"
  if [[ -z "$root_disk" ]]; then
    err "Could not determine the current root/system disk."
    err "For safety, refusing to format any NVMe target until the root disk is identified."
    err "Expected ODROID M1S layout: root/system disk on /dev/mmcblk*, Umbrel data disk on /dev/nvme*."
    return 1
  fi
  if [[ "$root_disk" != mmcblk* ]]; then
    err "This installer expects ODROID M1S to boot from eMMC (/dev/mmcblk*). Detected root disk: /dev/$root_disk"
    err "Refusing to format NVMe because it may be the system disk in this layout."
    return 1
  fi
}

assert_safe_root_target_layout() {
  if ! require_emmc_root_disk "$ROOT_DISK"; then
    return 1
  fi
  if [[ -z "$TARGET_DISK" ]]; then
    err "Could not determine target disk for: $TARGET_INPUT"
    return 1
  fi
  if [[ "$TARGET_DISK" == "$ROOT_DISK" ]]; then
    err "Refusing to format the root/system disk. Root disk: /dev/$ROOT_DISK, target: $TARGET_PARTITION"
    return 1
  fi
  require_nvme_target_disk "$TARGET_DISK"
}

require_nvme_target_disk() {
  local disk_name="$1"
  if [[ "$disk_name" != nvme* ]]; then
    err "This installer currently supports NVMe SSD targets only. Refusing non-NVMe target disk: /dev/$disk_name"
    return 1
  fi
}

preinstall_resume_attempted() {
  [[ -f "$PREINSTALL_RESUME_STATE_FILE" ]] || return 1
  python3 - "$PREINSTALL_RESUME_STATE_FILE" <<'PY'
import json, sys
try:
    with open(sys.argv[1], 'r', encoding='utf-8') as f:
        data = json.load(f)
except Exception:
    raise SystemExit(1)
raise SystemExit(0 if data.get('attempted_reboot_recovery') else 1)
PY
}

clear_preinstall_resume_state() {
  local unit_name
  unit_name="$(basename "$PREINSTALL_RESUME_SERVICE")"
  if [[ ! -f "$PREINSTALL_RESUME_SERVICE" && ! -f "$PREINSTALL_RESUME_STATE_FILE" ]]; then
    return 0
  fi
  if [[ "$DRY_RUN" -eq 1 ]]; then
    echo "[DRY-RUN] disable $unit_name"
    echo "[DRY-RUN] remove $PREINSTALL_RESUME_SERVICE"
    echo "[DRY-RUN] remove $PREINSTALL_RESUME_STATE_FILE"
    echo "[DRY-RUN] systemctl daemon-reload"
    return 0
  fi
  systemctl disable "$unit_name" >/dev/null 2>&1 || true
  rm -f "$PREINSTALL_RESUME_SERVICE" "$PREINSTALL_RESUME_STATE_FILE"
  systemctl daemon-reload >/dev/null 2>&1 || true
}

build_resume_command() {
  local cmd arg
  cmd="exec /bin/bash $(printf '%q' "$SCRIPT_PATH_ABS")"
  for arg in "${ORIGINAL_ARGS[@]}"; do
    cmd+=" $(printf '%q' "$arg")"
  done
  printf '%s\n' "$cmd"
}

write_preinstall_resume_state() {
  if [[ "$DRY_RUN" -eq 1 ]]; then
    echo "[DRY-RUN] write $PREINSTALL_RESUME_STATE_FILE"
    return 0
  fi
  mkdir -p "$INSTALL_STATE_DIR"
  python3 - "$PREINSTALL_RESUME_STATE_FILE" "$SCRIPT_PATH_ABS" "$(date -Is)" "${ORIGINAL_ARGS[@]}" <<'PY'
import json, os, sys, tempfile
path = sys.argv[1]
script_path = sys.argv[2]
created_at = sys.argv[3]
args = sys.argv[4:]
payload = {
    'script_path': script_path,
    'args': args,
    'attempted_reboot_recovery': True,
    'created_at': created_at,
}
d = os.path.dirname(path)
fd, tmp = tempfile.mkstemp(dir=d, prefix='preinstall-resume.tmp.')
with os.fdopen(fd, 'w', encoding='utf-8') as f:
    json.dump(payload, f, indent=2)
    f.write('\n')
os.chmod(tmp, 0o644)
os.rename(tmp, path)
PY
}

install_preinstall_resume_unit() {
  local resume_cmd unit_name
  unit_name="$(basename "$PREINSTALL_RESUME_SERVICE")"
  resume_cmd="$(build_resume_command)"
  if [[ "$DRY_RUN" -eq 1 ]]; then
    echo "[DRY-RUN] write $PREINSTALL_RESUME_SERVICE"
    echo "[DRY-RUN] systemctl daemon-reload"
    echo "[DRY-RUN] systemctl enable $unit_name"
    return 0
  fi
  cat > "$PREINSTALL_RESUME_SERVICE" <<EOF
[Unit]
Description=Resume ODROID M1S Umbrel install after NVMe recovery reboot
After=multi-user.target
ConditionPathExists=$PREINSTALL_RESUME_STATE_FILE

[Service]
Type=oneshot
TimeoutStartSec=infinity
ExecStart=/usr/bin/env AUTO_RESUME_INSTALL=1 /bin/bash -lc '$resume_cmd'

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable "$unit_name"
}

nvme_rescan_runtime() {
  if [[ "$DRY_RUN" -eq 1 ]]; then
    echo "[DRY-RUN] echo 1 > /sys/bus/pci/rescan"
    echo "[DRY-RUN] udevadm settle"
    return 0
  fi
  [[ -w /sys/bus/pci/rescan ]] || return 1
  printf '1\n' > /sys/bus/pci/rescan
  if command -v udevadm >/dev/null 2>&1; then
    udevadm settle || true
  fi
  sleep 3
  return 0
}

nvme_pci_remove_rescan() {
  local nvme_pci_remove_path="/sys/bus/pci/devices/0000:01:00.0/remove"
  if [[ "$DRY_RUN" -eq 1 ]]; then
    echo "[DRY-RUN] echo 1 > $nvme_pci_remove_path"
    echo "[DRY-RUN] echo 1 > /sys/bus/pci/rescan"
    echo "[DRY-RUN] udevadm settle"
    return 0
  fi
  [[ -w "$nvme_pci_remove_path" ]] || return 1
  [[ -w /sys/bus/pci/rescan ]] || return 1
  printf '1\n' > "$nvme_pci_remove_path"
  sleep 2
  printf '1\n' > /sys/bus/pci/rescan
  if command -v udevadm >/dev/null 2>&1; then
    udevadm settle || true
  fi
  sleep 3
  return 0
}

nvme_target_missing_preflight() {
  local parent=""
  if [[ -n "$TARGET_INPUT" ]]; then
    target_input_looks_like_nvme "$TARGET_INPUT" || return 1
    [[ -b "$TARGET_INPUT" ]] && return 1
    parent="$(guess_parent_disk_path "$TARGET_INPUT")"
    if [[ -n "$parent" && -b "$parent" ]]; then
      return 1
    fi
    return 0
  fi
  nvme_disk_visible && return 1
  return 0
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
      warn "flash-kernel not found. APST-off kernel parameter was recorded but boot script was not regenerated."
    fi
  else
    warn "$flash_kernel_defaults not found. Skipping APST-off kernel parameter setup."
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
  fi
}

apply_nvme_boot_mitigation() {
  info "Configuring conservative NVMe power policy for future boots"
  nvme_cmdline_patch_flash_kernel_defaults
  nvme_cmdline_patch_extlinux
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

maybe_recover_missing_nvme() {
  if [[ -z "$TARGET_INPUT" ]]; then
    if nvme_disk_visible; then
      return 0
    fi
    warn "No NVMe disk is currently visible. Attempting runtime PCI rescan before interactive disk selection."
    nvme_rescan_runtime || true
    if nvme_disk_visible; then
      info "Recovered NVMe visibility via runtime PCI rescan. Continuing installation."
      return 0
    fi

    warn "Runtime PCI rescan did not restore NVMe visibility. Attempting device-level PCI remove + rescan."
    nvme_pci_remove_rescan || true
    if nvme_disk_visible; then
      info "Recovered NVMe visibility via device-level PCI remove + rescan. Continuing installation."
      return 0
    fi

    if preinstall_resume_attempted; then
      clear_preinstall_resume_state
      err "NVMe is still missing after one automatic recovery reboot."
      err "Please inspect SSD seating, power, or firmware manually and rerun the installer."
      exit 1
    fi

    warn "Device-level PCI remove + rescan did not restore NVMe visibility. Applying boot-time NVMe mitigation and rebooting once."
    apply_nvme_boot_mitigation
    write_preinstall_resume_state
    install_preinstall_resume_unit
    if [[ "$DRY_RUN" -eq 1 ]]; then
      echo "[DRY-RUN] systemctl reboot"
      exit 0
    fi
    info "Rebooting once to resume installation after NVMe recovery."
    sync
    systemctl reboot
    exit 0
  fi

  if ! nvme_target_missing_preflight; then
    return 0
  fi

  warn "NVMe target is not visible before installation. Attempting runtime PCI rescan."
  nvme_rescan_runtime || true
  if ! nvme_target_missing_preflight; then
    info "Recovered NVMe visibility via runtime PCI rescan. Continuing installation."
    return 0
  fi

  warn "Runtime PCI rescan did not restore NVMe target visibility. Attempting device-level PCI remove + rescan."
  nvme_pci_remove_rescan || true
  if ! nvme_target_missing_preflight; then
    info "Recovered NVMe target visibility via device-level PCI remove + rescan. Continuing installation."
    return 0
  fi

  if preinstall_resume_attempted; then
    clear_preinstall_resume_state
    err "NVMe target is still missing after one automatic recovery reboot."
    err "Please inspect SSD seating, power, or firmware manually and rerun the installer."
    exit 1
  fi

  warn "Device-level PCI remove + rescan did not restore NVMe target visibility. Applying boot-time NVMe mitigation and rebooting once."
  apply_nvme_boot_mitigation
  write_preinstall_resume_state
  install_preinstall_resume_unit
  if [[ "$DRY_RUN" -eq 1 ]]; then
    echo "[DRY-RUN] systemctl reboot"
    exit 0
  fi
  info "Rebooting once to resume installation after NVMe recovery."
  sync
  systemctl reboot
  exit 0
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
  ufw --force disable >/dev/null || warn "Failed to disable UFW; Umbrel app networking may remain blocked by host firewall rules."
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

get_exact_data_mount_source() {
  findmnt -rn -M "$DATA_DIR" -o SOURCE 2>/dev/null || true
}

wait_for_exact_data_mount() {
  local expected_source="$1"
  local current_source=""
  local _attempt

  for _attempt in {1..10}; do
    current_source="$(get_exact_data_mount_source)"
    if [[ "$current_source" == "$expected_source" ]]; then
      return 0
    fi
    sleep 1
  done

  printf '%s\n' "$current_source"
  return 1
}

unmount_all_layers_at_path() {
  local mount_path="$1"

  while findmnt -rn -M "$mount_path" >/dev/null 2>&1; do
    umount "$mount_path"
  done
}

report_install_health() {
  local lan_iface="${1:-}"
  local lan_ip="${2:-}"
  local current_data_source docker_state avahi_state alias_state container_state local_resolve_state ip_http_state local_http_state avahi_config_state

  current_data_source="$(get_exact_data_mount_source)"
  docker_state="$(systemctl is-active docker 2>/dev/null || true)"
  avahi_state="$(systemctl is-active avahi-daemon 2>/dev/null || true)"
  alias_state="$(systemctl is-active avahi-alias-umbrel.service 2>/dev/null || true)"
  container_state="$(docker inspect --format='{{.State.Status}}' umbrel 2>/dev/null || true)"
  if m1s_avahi_internal_health_check; then
    avahi_config_state="clean"
  else
    avahi_config_state="failed"
  fi

  if getent hosts umbrel.local >/dev/null 2>&1; then
    local_resolve_state="ok"
  else
    local_resolve_state="failed"
  fi

  if [[ -n "$lan_ip" ]] && curl -fsS --max-time 10 "http://$lan_ip" >/dev/null 2>&1; then
    ip_http_state="ok"
  else
    ip_http_state="failed"
  fi

  if curl -fsS --max-time 10 http://umbrel.local >/dev/null 2>&1; then
    local_http_state="ok"
  else
    local_http_state="failed"
  fi

  info "Install health summary"
  info "- LAN interface: ${lan_iface:-unknown}"
  info "- LAN IP: ${lan_ip:-unknown}"
  info "- Data mount: ${current_data_source:-NOT_MOUNTED} -> $DATA_DIR"
  info "- Docker service: ${docker_state:-unknown}"
  info "- Umbrel container: ${container_state:-unknown}"
  info "- avahi-daemon: ${avahi_state:-unknown}"
  info "- avahi alias service: ${alias_state:-unknown}"
  info "- mDNS config self-check: ${avahi_config_state:-unknown}"
  info "- umbrel.local host resolve: ${local_resolve_state:-unknown}"
  info "- HTTP by device IP: ${ip_http_state:-unknown}"
  info "- HTTP by umbrel.local: ${local_http_state:-unknown}"

  if [[ "$current_data_source" != "$TARGET_PARTITION" ]]; then
    err "Health check failed: expected $TARGET_PARTITION mounted at $DATA_DIR, got ${current_data_source:-NOT_MOUNTED}."
    exit 1
  fi
  if [[ "$docker_state" != "active" ]]; then
    err "Health check failed: docker.service is not active."
    exit 1
  fi
  if [[ "$container_state" != "running" ]]; then
    err "Health check failed: Umbrel container is not running."
    exit 1
  fi
  if [[ "$avahi_config_state" != "clean" ]]; then
    err "Health check failed: the managed mDNS configuration is not canonical."
    exit 1
  fi
  if [[ "$avahi_state" != "active" ]]; then
    warn "avahi-daemon is not active. umbrel.local may fail; use http://${lan_ip:-<device-ip>} instead."
  fi
  if [[ "$alias_state" != "active" ]]; then
    warn "avahi-alias-umbrel.service is not active. umbrel.local may fail; use http://${lan_ip:-<device-ip>} instead."
  fi
  if [[ "$local_http_state" != "ok" && "$ip_http_state" == "ok" ]]; then
    warn "External mDNS resolution failed while HTTP by device IP succeeded. Check the client VPN, router multicast filtering, or client resolver; use http://${lan_ip:-<device-ip>} meanwhile."
  elif [[ "$local_http_state" != "ok" ]]; then
    warn "umbrel.local and the device-IP HTTP check did not answer from this host; use http://${lan_ip:-<device-ip>} for follow-up diagnostics."
  fi
}

wait_for_umbrel_container() {
  local attempts=30
  local delay=2
  local state=""
  local i

  for ((i=0; i<attempts; i++)); do
    state="$(docker inspect --format='{{.State.Status}}' umbrel 2>/dev/null || true)"
    if [[ "$state" == "running" ]]; then
      return 0
    fi
    sleep "$delay"
  done

  err "Umbrel container did not reach running state (last state: ${state:-unknown})."
  return 1
}

verify_pulled_umbrel_image() {
  local image_id="" image_architecture=""

  image_id="$(docker image inspect --format='{{.Id}}' "$IMAGE" 2>/dev/null || true)"
  image_architecture="$(docker image inspect --format='{{.Architecture}}' "$IMAGE" 2>/dev/null || true)"
  if [[ -z "$image_id" ]]; then
    err "Pulled Umbrel image did not provide the expected arm64 image ID."
    return 1
  fi
  if [[ "$image_architecture" != "arm64" ]]; then
    err "Pulled Umbrel image architecture is ${image_architecture:-missing}, not arm64."
    return 1
  fi
  RESOLVED_UMBREL_IMAGE_ID="$image_id"
  RESOLVED_UMBREL_IMAGE_ARCHITECTURE="$image_architecture"
}

pull_and_verify_umbrel_image() {
  RESOLVED_UMBREL_IMAGE_ID=""
  RESOLVED_UMBREL_IMAGE_ARCHITECTURE=""
  run_cmd docker pull "$IMAGE"

  if [[ "$DRY_RUN" -eq 0 ]]; then
    verify_pulled_umbrel_image
  fi
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
import base64
import hashlib
import json
import os
import re
import sys
from pathlib import Path

ROOT = Path(os.environ.get('M1S_TEST_UMBREL_UI_ROOT', '/opt/umbreld/ui')).resolve()
INDEX = ROOT / 'index.html'
SERVER_SOURCE = Path(os.environ.get('M1S_TEST_UMBREL_SERVER_SOURCE', '/opt/umbreld/source/modules/server/index.ts')).resolve()
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


def configure_import_map_csp(original_ref, target_ref):
    if not SERVER_SOURCE.is_file():
        fail('Umbrel server CSP source is missing')
    payload = json.dumps({'imports': {original_ref: target_ref}}, separators=(',', ':')).encode()
    digest = base64.b64encode(hashlib.sha256(payload).digest()).decode()
    prefix = "scriptSrc: this.umbreld.developmentMode ? [\"'self'\", \"'unsafe-inline'\"] : "
    replacement = f"{prefix}[\"'self'\", \"'sha256-{digest}'\"], // m1s-shutdown-ui-csp"
    lines = SERVER_SOURCE.read_text(encoding='utf-8').splitlines(keepends=True)
    matches = [index for index, line in enumerate(lines) if line.strip().startswith(prefix)]
    if len(matches) != 1:
        fail('expected exactly one Umbrel production scriptSrc CSP directive')
    newline = '\n' if lines[matches[0]].endswith('\n') else ''
    indent = lines[matches[0]][:len(lines[matches[0]]) - len(lines[matches[0]].lstrip())]
    lines[matches[0]] = f'{indent}{replacement}{newline}'
    atomic_write(SERVER_SOURCE, ''.join(lines).encode())


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
        configure_import_map_csp(original_ref, ref)
        raise SystemExit(0)
    insertion_start = min(trigger_starts)
    atomic_write(INDEX, (index_text[:insertion_start] + managed_import_map_tag(original_ref, ref) + index_text[insertion_start:]).encode('utf-8'))
    configure_import_map_csp(original_ref, ref)
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
    configure_import_map_csp(ref, new_ref)
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
import base64
import hashlib
import json
import os
import re
import sys
from pathlib import Path

ROOT = Path(os.environ.get('M1S_TEST_UMBREL_UI_ROOT', '/opt/umbreld/ui')).resolve()
INDEX = ROOT / 'index.html'
SERVER_SOURCE = Path(os.environ.get('M1S_TEST_UMBREL_SERVER_SOURCE', '/opt/umbreld/source/modules/server/index.ts')).resolve()
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
if not SERVER_SOURCE.is_file():
    fail('Umbrel server CSP source is missing')
payload = json.dumps({'imports': {original_ref: ref}}, separators=(',', ':')).encode()
digest = base64.b64encode(hashlib.sha256(payload).digest()).decode()
expected_csp = f"scriptSrc: this.umbreld.developmentMode ? [\"'self'\", \"'unsafe-inline'\"] : [\"'self'\", \"'sha256-{digest}'\"], // m1s-shutdown-ui-csp"
if expected_csp not in SERVER_SOURCE.read_text(encoding='utf-8'):
    fail('Umbrel CSP does not authorize the managed import map')
PY_INNER
}

is_expected_tor_proxy_image() {
  local image_ref="$1"
  [[ "$image_ref" == "$EXPECTED_TOR_PROXY_IMAGE" ]] && return 0
  [[ "$image_ref" =~ ^ghcr.io/getumbrel/tor:0\.4\.9\.11@sha256:[0-9a-f]{64}$ ]]
}

umbrel_runtime_health_once() {
  local container_state image_ref image_id restart_policy data_mount_source docker_socket_source auth_state tor_proxy_state tor_proxy_image

  container_state="$(docker inspect --format='{{.State.Status}}' umbrel 2>/dev/null || true)"
  image_ref="$(docker inspect --format='{{.Config.Image}}' umbrel 2>/dev/null || true)"
  image_id="$(docker inspect --format='{{.Image}}' umbrel 2>/dev/null || true)"
  restart_policy="$(docker inspect --format='{{.HostConfig.RestartPolicy.Name}}' umbrel 2>/dev/null || true)"
  data_mount_source="$(docker inspect --format='{{range .Mounts}}{{if eq .Destination "/data"}}{{.Source}}{{end}}{{end}}' umbrel 2>/dev/null || true)"
  docker_socket_source="$(docker inspect --format='{{range .Mounts}}{{if eq .Destination "/var/run/docker.sock"}}{{.Source}}{{end}}{{end}}' umbrel 2>/dev/null || true)"
  auth_state="$(docker inspect --format='{{.State.Status}}' "$CANONICAL_AUTH_CONTAINER" 2>/dev/null || true)"
  tor_proxy_state="$(docker inspect --format='{{.State.Status}}' "$CANONICAL_TOR_PROXY_CONTAINER" 2>/dev/null || true)"
  tor_proxy_image="$(docker inspect --format='{{.Config.Image}}' "$CANONICAL_TOR_PROXY_CONTAINER" 2>/dev/null || true)"

  if [[ "$container_state" != "running" ]]; then
    err "Runtime health failed: umbrel container is ${container_state:-missing}, not running."
    return 1
  fi
  if [[ "$image_ref" != "$IMAGE" ]]; then
    err "Runtime health failed: umbrel image ref is ${image_ref:-missing}, not the expected pinned image."
    return 1
  fi
  if [[ -z "$RESOLVED_UMBREL_IMAGE_ID" || "$RESOLVED_UMBREL_IMAGE_ARCHITECTURE" != "arm64" ]]; then
    err "Runtime health failed: pulled Umbrel image metadata is missing or not arm64."
    return 1
  fi
  if [[ "$image_id" != "$RESOLVED_UMBREL_IMAGE_ID" ]]; then
    err "Runtime health failed: umbrel image ID is ${image_id:-missing}, not the pulled arm64 image ID."
    return 1
  fi
  if [[ "$restart_policy" != "always" ]]; then
    err "Runtime health failed: umbrel restart policy is ${restart_policy:-missing}, not always."
    return 1
  fi
  if [[ "$data_mount_source" != "$HOST_DATA_ALIAS" ]]; then
    err "Runtime health failed: umbrel /data mount is ${data_mount_source:-missing}, not $HOST_DATA_ALIAS."
    return 1
  fi
  if [[ "$docker_socket_source" != "/var/run/docker.sock" ]]; then
    err "Runtime health failed: umbrel Docker socket mount is ${docker_socket_source:-missing}."
    return 1
  fi
  if ! verify_umbrel_shutdown_source; then
    err "Runtime health failed: Umbrel safe-shutdown source patch is missing."
    return 1
  fi
  if ! verify_umbrel_shutdown_ui; then
    err "Runtime health failed: Umbrel shutdown UI timer patch is missing."
    return 1
  fi
  if ! curl -fsS --max-time 10 http://127.0.0.1 >/dev/null 2>&1; then
    err "Runtime health failed: Umbrel HTTP endpoint did not respond locally."
    return 1
  fi
  if [[ "$auth_state" != "running" ]]; then
    err "Runtime health failed: $CANONICAL_AUTH_CONTAINER container is ${auth_state:-missing}, not running."
    return 1
  fi
  if [[ "$tor_proxy_state" != "running" ]]; then
    err "Runtime health failed: $CANONICAL_TOR_PROXY_CONTAINER container is ${tor_proxy_state:-missing}, not running."
    return 1
  fi
  if ! is_expected_tor_proxy_image "$tor_proxy_image"; then
    err "Runtime health failed: $CANONICAL_TOR_PROXY_CONTAINER image is ${tor_proxy_image:-missing}, not $EXPECTED_TOR_PROXY_IMAGE or an exact sha256-pinned form."
    return 1
  fi
}

wait_for_umbrel_runtime_health() {
  local attempt

  for ((attempt = 1; attempt <= UMBREL_RUNTIME_HEALTH_ATTEMPTS; attempt++)); do
    if umbrel_runtime_health_once >/dev/null 2>&1; then
      return 0
    fi
    if (( attempt < UMBREL_RUNTIME_HEALTH_ATTEMPTS )); then
      sleep "$UMBREL_RUNTIME_HEALTH_DELAY"
    fi
  done

  err "Umbrel runtime health did not meet the required contract after $UMBREL_RUNTIME_HEALTH_ATTEMPTS attempts."
  umbrel_runtime_health_once
}

record_install_state() {
  local image_ref image_id install_timestamp

  if ! umbrel_runtime_health_once; then
    err "Refusing to record successful install state before runtime health passes."
    return 1
  fi

  image_ref="$(docker inspect --format='{{.Config.Image}}' umbrel 2>/dev/null || true)"
  image_id="$(docker inspect --format='{{.Image}}' umbrel 2>/dev/null || true)"
  if [[ "$image_ref" != "$IMAGE" || "$image_id" != "$RESOLVED_UMBREL_IMAGE_ID" ]]; then
    err "Refusing to record install state because live Umbrel image metadata does not match the expected arm64 image."
    return 1
  fi

  mkdir -p "$INSTALL_STATE_DIR"
  install_timestamp="$(date -Is)"
  python3 - "$INSTALL_STATE_FILE" "$INSTALL_STATE_VERSION" "$install_timestamp" "$image_ref" "$image_id" "$DATA_DIR" "$TARGET_PARTITION" <<'PY'
import json, os, sys, tempfile
path, version, ts, image, image_id, data_dir, target = sys.argv[1:8]
payload = {
    "version": version,
    "host_version": version,
    "installed_at": ts,
    "installed_by": "m1s-clean-install-umbrel.sh",
    "image": image,
    "image_id": image_id,
    "data_dir": data_dir,
    "target_partition": target,
    "applied_steps": [],
    "in_progress_step": None,
    "failed_step": None,
    "last_error": None,
}
d = os.path.dirname(path)
fd, tmp = tempfile.mkstemp(dir=d, prefix="installed.tmp.")
with os.fdopen(fd, "w") as f:
    json.dump(payload, f, indent=2)
    f.write("\n")
os.chmod(tmp, 0o644)
os.rename(tmp, path)
PY
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

autoselect_target_disk_if_single_candidate() {
  local candidate_paths=()
  local disk_path disk_name line

  if [[ -z "$ROOT_DISK" ]]; then
    return 1
  fi

  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    unset NAME SIZE TYPE MODEL
    eval "$line"
    [[ "${TYPE:-}" == "disk" ]] || continue
    # shellcheck disable=SC2153 # NAME is assigned by eval from lsblk -P output.
    disk_path="/dev/${NAME}"
    [[ -z "$disk_path" ]] && continue
    disk_name="$(basename "$disk_path")"
    if [[ -n "$ROOT_DISK" && "$disk_name" == "$ROOT_DISK" ]]; then
      continue
    fi
    if [[ "$disk_name" != nvme* ]]; then
      continue
    fi
    candidate_paths+=("$disk_path")
  done < <(lsblk -dn -o NAME,SIZE,TYPE,MODEL -P 2>/dev/null)

  if [[ "${#candidate_paths[@]}" -ne 1 ]]; then
    return 1
  fi

  TARGET_INPUT="${candidate_paths[0]}"
  info "Exactly one non-root NVMe SSD was detected ($TARGET_INPUT). Selecting it automatically."
  return 0
}

select_target_disk_interactive() {
  local candidate_paths=()
  local candidate_sizes=()
  local candidate_models=()
  local candidate_mounts=()
  local candidate_parts=()
  local disk_path size model mounts part_count disk_name choice index line

  if [[ -z "$ROOT_DISK" ]]; then
    err "Could not determine the current root/system disk automatically."
    err "For safety, rerun with --target-partition and specify the intended SSD disk or partition explicitly."
    exit 1
  fi

  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    unset NAME SIZE TYPE MODEL
    eval "$line"
    [[ "${TYPE:-}" == "disk" ]] || continue
    # shellcheck disable=SC2153 # NAME is assigned by eval from lsblk -P output.
    disk_path="/dev/${NAME}"
    size="${SIZE:-unknown}"
    model="${MODEL:-unknown}"
    [[ -z "$disk_path" ]] && continue
    disk_name="$(basename "$disk_path")"
    if [[ -n "$ROOT_DISK" && "$disk_name" == "$ROOT_DISK" ]]; then
      continue
    fi
    if [[ "$disk_name" != nvme* ]]; then
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
    err "No candidate NVMe SSD storage disks were found."
    err "Connect a supported NVMe SSD, then rerun this installer."
    exit 1
  fi

  echo
  echo "Detected non-root NVMe SSD storage disks:"
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
    read_prompt_or_abort choice "Choose the storage disk to initialize [1-${#candidate_paths[@]}] (or q to quit): "
    if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#candidate_paths[@]} )); then
      local selected="${candidate_paths[$((choice - 1))]}"
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
  --image IMAGE              Docker image to run (default: pinned dockurr/umbrel 1.7.4 digest)
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
        err "--image requires a value (e.g. --image dockurr/umbrel:1.7.4)"
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

if [[ "${M1S_INSTALLER_LIB_ONLY:-0}" == "1" ]]; then
  # shellcheck disable=SC2317 # Used when the installer is sourced by unit tests.
  return 0 2>/dev/null || exit 0
fi

trap cleanup_on_exit EXIT

m1s_report_host_support

if [[ "${EUID}" -ne 0 ]]; then
  err "Run this script with sudo or as root."
  exit 1
fi

# shellcheck disable=SC1091
source /etc/os-release
ARCH="$(uname -m)"

for required_cmd in python3 curl blkid mkfs.ext4 lsblk findmnt; do
  if ! command -v "$required_cmd" >/dev/null 2>&1; then
    err "Required command '$required_cmd' is not installed."
    exit 1
  fi
done

SCRIPT_PATH_ABS="$(resolve_block_path "$0")"

MODEL="unknown"
if [[ -r /proc/device-tree/model ]]; then
  MODEL="$(tr -d '\0' </proc/device-tree/model)"
elif [[ -r /sys/firmware/devicetree/base/model ]]; then
  MODEL="$(tr -d '\0' </sys/firmware/devicetree/base/model)"
fi
ROOT_SOURCE="$(findmnt -n -o SOURCE / || true)"
ROOT_DISK="$(detect_root_disk "$ROOT_SOURCE")"
TARGET_DISK=""
CURRENT_DATA_SOURCE="$(findmnt -n -o SOURCE --target "$DATA_DIR" 2>/dev/null || true)"
EXISTING_TARGET_MOUNT=""

if ! require_emmc_root_disk "$ROOT_DISK"; then
  err "Detected root source: ${ROOT_SOURCE:-unknown}"
  err "Target input: ${TARGET_INPUT:-interactive selection not reached}"
  exit 1
fi

maybe_recover_missing_nvme

if [[ -z "$TARGET_INPUT" ]]; then
  autoselect_target_disk_if_single_candidate || select_target_disk_interactive
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

if ! assert_safe_root_target_layout; then
  err "Detected root source: ${ROOT_SOURCE:-unknown}"
  err "Detected root disk: ${ROOT_DISK:-unknown}"
  err "Target disk: ${TARGET_DISK:-unknown}"
  err "Target partition: ${TARGET_PARTITION:-unknown}"
  exit 1
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

if findmnt -rn -M "$HOST_DATA_ALIAS" >/dev/null 2>&1 && append_unique "$HOST_DATA_ALIAS" "${TARGET_MOUNT_PATHS[@]}"; then
  TARGET_MOUNT_PATHS=("$HOST_DATA_ALIAS" "${TARGET_MOUNT_PATHS[@]}")
fi

while IFS= read -r swap_path; do
  [[ -z "$swap_path" ]] && continue
  if append_unique "$swap_path" "${TARGET_SWAP_PATHS[@]}"; then
    TARGET_SWAP_PATHS+=("$swap_path")
  fi
done < <(swapon --show=NAME --noheadings --raw 2>/dev/null | while read -r p; do
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
  if [[ "$AUTO_RESUME_INSTALL" -ne 1 ]]; then
    read_prompt_or_abort CONFIRM "Type ERASE-EMMC-AND-FORMAT-SSD-AND-INSTALL-UMBREL to continue, or q to quit: "
    if [[ "$CONFIRM" != "ERASE-EMMC-AND-FORMAT-SSD-AND-INSTALL-UMBREL" ]]; then
      err "Confirmation text mismatch. Aborting."
      exit 1
    fi
  else
    info "Resume mode: skipping destructive confirmation prompt after prior recovery reboot."
  fi
fi

if [[ "$AUTO_RESUME_INSTALL" -ne 1 ]]; then
  clear_preinstall_resume_state
fi

# Make sure unattended-upgrades or any other apt consumer is not holding the
# dpkg lock. If we continue while the lock is held, apt purge/update/install
# operations can fail midway. After the current apt operation finishes, pause
# apt automation so it cannot reacquire the lock during this install run.
wait_for_apt_locks
pause_apt_automation
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
m1s_backup_file_with_retention /etc/fstab '.bak' '+%s'

info "Cleaning fstab entries that belong to RaspiBlitz eMMC setup"
TARGET_SWAP_PATHS_STR="${TARGET_SWAP_PATHS[*]}"
TARGET_MOUNT_PATHS_STR="${TARGET_MOUNT_PATHS[*]}"
TARGET_EXISTING_PARTITIONS_STR="${TARGET_EXISTING_PARTITIONS[*]}"
TARGET_UUID_BEFORE_FORMAT="$(blkid -s UUID -o value "$TARGET_PARTITION" 2>/dev/null || true)"
if [[ "$DRY_RUN" -eq 1 ]]; then
  run_shell "TARGET_MOUNT_PATHS_STR=${TARGET_MOUNT_PATHS_STR@Q} DATA_DIR_VALUE=${DATA_DIR@Q} TARGET_UUID_VALUE=${TARGET_UUID_BEFORE_FORMAT@Q} TARGET_SWAP_PATHS_STR=${TARGET_SWAP_PATHS_STR@Q} TARGET_EXISTING_PARTITIONS_STR=${TARGET_EXISTING_PARTITIONS_STR@Q} python3 <clean-fstab-script>"
else
  TARGET_MOUNT_PATHS_STR="$TARGET_MOUNT_PATHS_STR" \
  DATA_DIR_VALUE="$DATA_DIR" \
  TARGET_UUID_VALUE="$TARGET_UUID_BEFORE_FORMAT" \
  TARGET_SWAP_PATHS_STR="$TARGET_SWAP_PATHS_STR" \
  TARGET_EXISTING_PARTITIONS_STR="$TARGET_EXISTING_PARTITIONS_STR" \
  python3 - <<'PY'
from pathlib import Path
import os, tempfile
fstab = Path('/etc/fstab')
text = fstab.read_text()
lines = text.splitlines()
filtered = []
target_mounts = [p for p in os.environ.get('TARGET_MOUNT_PATHS_STR', '').split() if p]
data_dir = os.environ.get('DATA_DIR_VALUE', '')
target_uuid = os.environ.get('TARGET_UUID_VALUE', '')
target_swaps = [p for p in os.environ.get('TARGET_SWAP_PATHS_STR', '').split() if p]
target_devices = [p for p in os.environ.get('TARGET_EXISTING_PARTITIONS_STR', '').split() if p]

def source_matches_target(source):
    if source in target_devices:
        return True
    if target_uuid and source in ('UUID=' + target_uuid, 'UUID="' + target_uuid + '"'):
        return True
    return False

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
    if data_dir and mountpoint == data_dir and source_matches_target(source):
        continue
    if mountpoint == '/mnt/ssd':
        continue
    if mountpoint == '/mnt/nvme':
        continue
    if source in target_swaps:
        continue
    if source_matches_target(source):
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
PY
fi

enter_destructive_storage_window
run_cmd systemctl daemon-reload
run_cmd systemctl stop mnt-fullnode-swapfile.swap data.mount mnt-fullnode.mount || true

info "Formatting and mounting SSD for Umbrel data"
if [[ "$DRY_RUN" -eq 1 ]]; then
  echo "[DRY-RUN] stop existing fullnode-mount-guard timer/service before remounting $DATA_DIR"
else
  systemctl stop fullnode-mount-guard.timer fullnode-mount-guard.service >/dev/null 2>&1 || true
fi
run_cmd mkdir -p "$DATA_DIR"
if command -v fuser >/dev/null 2>&1; then
  info "Checking for processes still using the current SSD mount"
  for mount_path in "${TARGET_MOUNT_PATHS[@]}"; do
    [[ -n "$mount_path" ]] || continue
    run_shell "fuser -vm '$mount_path' || true"
  done
fi
stop_target_busy_processes
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
    swapoff "$swap_path" >/dev/null 2>&1 || true
  done
  while IFS= read -r active_swap; do
    [[ -z "$active_swap" ]] && continue
    err "Target swap is still active after swapoff attempt: $active_swap"
    err "Disable swap users on the SSD and try again."
    exit 1
  done < <(swapon --show=NAME --noheadings --raw 2>/dev/null | while read -r p; do
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
    unmount_all_layers_at_path "$mount_path" >/dev/null 2>&1 || true
  done
  for target_dev in "${TARGET_EXISTING_PARTITIONS[@]}"; do
    [[ -n "$target_dev" ]] || continue
    umount "$target_dev" >/dev/null 2>&1 || true
  done
  if [[ "$TARGET_MODE" == "partition" ]]; then
    umount "$TARGET_PARTITION" >/dev/null 2>&1 || true
  fi
  unmount_all_layers_at_path "$HOST_DATA_ALIAS" >/dev/null 2>&1 || true
  unmount_all_layers_at_path "$DATA_DIR" >/dev/null 2>&1 || true

  for mount_path in "$HOST_DATA_ALIAS" "$DATA_DIR"; do
    if findmnt -rn -M "$mount_path" >/dev/null 2>&1; then
      err "Mount point is still active after unmount attempts: $mount_path"
      err "Inspect with: sudo findmnt -R $mount_path && sudo fuser -vm $mount_path"
      exit 1
    fi
  done

  for target_dev in "${TARGET_EXISTING_PARTITIONS[@]}"; do
    [[ -n "$target_dev" ]] || continue
    if findmnt -rn -S "$target_dev" >/dev/null 2>&1; then
      warn "Target device is still mounted after first unmount attempt: $target_dev"
      stop_target_busy_processes
      umount "$target_dev" >/dev/null 2>&1 || true
      if findmnt -rn -S "$target_dev" >/dev/null 2>&1; then
        err "Target device is still mounted after automatic SSD process cleanup: $target_dev"
        err "Reboot the ODROID M1S and rerun the installer, or inspect with: sudo fuser -vm $target_dev"
        exit 1
      fi
    fi
  done

  CURRENT_DATA_SOURCE="$(findmnt -rn -o SOURCE -T "$DATA_DIR" 2>/dev/null || true)"
  if [[ -n "$CURRENT_DATA_SOURCE" && "$CURRENT_DATA_SOURCE" != "$ROOT_SOURCE" && "$CURRENT_DATA_SOURCE" != "tmpfs" ]]; then
    warn "Data directory is still backed by a non-root mounted filesystem after first unmount attempt: $DATA_DIR -> $CURRENT_DATA_SOURCE"
    stop_target_busy_processes
    unmount_all_layers_at_path "$HOST_DATA_ALIAS" >/dev/null 2>&1 || true
    unmount_all_layers_at_path "$DATA_DIR" >/dev/null 2>&1 || true
    CURRENT_DATA_SOURCE="$(findmnt -rn -o SOURCE -T "$DATA_DIR" 2>/dev/null || true)"
    if [[ -n "$CURRENT_DATA_SOURCE" && "$CURRENT_DATA_SOURCE" != "$ROOT_SOURCE" && "$CURRENT_DATA_SOURCE" != "tmpfs" ]]; then
      err "Data directory is still busy after automatic SSD process cleanup: $DATA_DIR -> $CURRENT_DATA_SOURCE"
      err "Reboot the ODROID M1S and rerun the installer, or inspect with: sudo fuser -vm $DATA_DIR"
      err "Kernel storage clues: sudo journalctl -k -b --no-pager | grep -Ei 'nvme|I/O error|EXT4'"
      exit 1
    fi
  fi
fi

if [[ "$TARGET_MODE" == "raw-disk" ]]; then
  repartition_raw_disk
fi

run_cmd mkfs.ext4 -F "$TARGET_PARTITION"

TARGET_UUID=""
if [[ "$DRY_RUN" -eq 1 ]]; then
  TARGET_UUID="DRYRUN-UUID"
else
  TARGET_UUID="$(blkid -s UUID -o value "$TARGET_PARTITION")"
fi

if [[ -z "$TARGET_UUID" ]]; then
  err "Could not determine UUID for $TARGET_PARTITION after formatting."
  exit 1
fi

run_cmd mount "$TARGET_PARTITION" "$DATA_DIR"
run_cmd chown -R root:root "$DATA_DIR"

if [[ "$DRY_RUN" -eq 1 ]]; then
  run_shell "FSTAB_UUID=${TARGET_UUID@Q} FSTAB_MOUNT=${DATA_DIR@Q} python3 <write-fullnode-fstab-script>"
else
  FSTAB_UUID="$TARGET_UUID" FSTAB_MOUNT="$DATA_DIR" python3 - <<'PY'
from pathlib import Path
import os, tempfile
fstab = Path('/etc/fstab')
uuid_val = os.environ['FSTAB_UUID']
mount_val = os.environ['FSTAB_MOUNT']
entry = 'UUID={}\t{}\text4\tdefaults,auto,exec,rw,nofail,x-systemd.device-timeout=10s\t0\t0'.format(uuid_val, mount_val)
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
PY
fi

if [[ "$DRY_RUN" -eq 0 ]]; then
  if ! CURRENT_DATA_SOURCE="$(wait_for_exact_data_mount "$TARGET_PARTITION")"; then
    err "Mount verification failed. Expected $TARGET_PARTITION at $DATA_DIR, got ${CURRENT_DATA_SOURCE:-NOT_MOUNTED}."
    exit 1
  fi
fi

apply_nvme_boot_mitigation
remove_pwm_fan_config
ensure_nvme_diagnostic_tools
install_nvme_timeout_snapshotter
install_fstrim_dropin

info "Disabling automatic reboot from unattended-upgrades"
APT_NOREBOOT_FILE="/etc/apt/apt.conf.d/52m1s-no-auto-reboot"
if [[ "$DRY_RUN" -eq 1 ]]; then
  echo "[DRY-RUN] write $APT_NOREBOOT_FILE"
else
  cat > "$APT_NOREBOOT_FILE" <<'APT_CONF'
Unattended-Upgrade::Automatic-Reboot "false";
Unattended-Upgrade::Automatic-Reboot-WithUsers "false";
APT_CONF
  chmod 0644 "$APT_NOREBOOT_FILE"
  info "Wrote $APT_NOREBOOT_FILE (automatic reboot is now disabled)"
fi

info "Ensuring a swapfile exists on $DATA_DIR"
SWAPFILE="$DATA_DIR/swapfile"
SWAP_SIZE_MB=4096
if [[ "$DRY_RUN" -eq 1 ]]; then
  echo "[DRY-RUN] create $SWAPFILE (${SWAP_SIZE_MB}MB), mkswap, swapon, add to /etc/fstab"
else
  if swapon --show=NAME --noheadings --raw 2>/dev/null | grep -qx "$SWAPFILE"; then
    info "Swapfile $SWAPFILE already active; skipping"
  else
    if [[ ! -f "$SWAPFILE" ]]; then
      if command -v fallocate >/dev/null 2>&1; then
        fallocate -l "${SWAP_SIZE_MB}M" "$SWAPFILE"
      else
        dd if=/dev/zero of="$SWAPFILE" bs=1M count="$SWAP_SIZE_MB" status=none
      fi
    fi
    chmod 600 "$SWAPFILE"
    mkswap "$SWAPFILE" >/dev/null || warn "mkswap $SWAPFILE failed (continuing)"
    swapon "$SWAPFILE" || warn "swapon $SWAPFILE failed (continuing)"
    if ! grep -qE "^${SWAPFILE}[[:space:]]" /etc/fstab; then
      printf '%s\tnone\tswap\tsw,nofail\t0\t0\n' "$SWAPFILE" >> /etc/fstab
      info "Added $SWAPFILE to /etc/fstab"
    fi
  fi
fi

install_docker_engine_from_official_apt_repo() {
  local docker_keyring="/etc/apt/keyrings/docker.asc"
  local docker_list="/etc/apt/sources.list.d/docker.list"
  local docker_arch docker_codename

  docker_arch="$(dpkg --print-architecture)"
  docker_codename="${VERSION_CODENAME:-${UBUNTU_CODENAME:-}}"
  if [[ -z "$docker_codename" ]]; then
    err "Could not determine the Ubuntu codename for the Docker apt repository."
    return 1
  fi

  if [[ "$DRY_RUN" -eq 1 ]]; then
    echo "[DRY-RUN] install Docker apt keyring at $docker_keyring"
    echo "[DRY-RUN] write Docker apt source for Ubuntu $docker_codename ($docker_arch) to $docker_list"
    echo "[DRY-RUN] apt-get -o DPkg::Lock::Timeout=300 update"
    echo "[DRY-RUN] apt-get -o DPkg::Lock::Timeout=300 install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin"
    return 0
  fi

  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o "$docker_keyring"
  chmod a+r "$docker_keyring"
  printf 'deb [arch=%s signed-by=%s] https://download.docker.com/linux/ubuntu %s stable\n' \
    "$docker_arch" "$docker_keyring" "$docker_codename" > "$docker_list"
  chmod 0644 "$docker_list"
  wait_for_apt_locks
  apt-get -o DPkg::Lock::Timeout=300 update
  wait_for_apt_locks
  DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=300 install -y \
    docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
}

info "Installing fresh Docker from Docker's official apt repository"
if ! install_docker_engine_from_official_apt_repo; then
  err "Docker installation failed."
  err "The SSD has already been formatted and mounted at $DATA_DIR."
  err "If you are following the public guide, wait a moment and rerun the same installer command first."
  err "Do not delete apt/dpkg lock files or kill unattended-upgrades manually unless you know exactly why."
  err "If the same error repeats, keep a photo or copy of this output and ask for help."
  err "Advanced recovery only: to retry Docker installation without rerunning the installer, configure Docker's official Ubuntu apt repository and install:"
  err "  sudo apt-get -o DPkg::Lock::Timeout=300 install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin"
  err "Then start Umbrel manually:"
  err "  sudo docker run -d --name umbrel --restart always -p 80:80 -v $DATA_DIR:/data -v /var/run/docker.sock:/var/run/docker.sock --stop-timeout 60 --pid=host --privileged $IMAGE"
  exit 1
fi

info "Configuring Docker log rotation"
DOCKER_DAEMON_JSON="/etc/docker/daemon.json"
if [[ "$DRY_RUN" -eq 1 ]]; then
  echo "[DRY-RUN] write $DOCKER_DAEMON_JSON with log-driver json-file, max-size=10m, max-file=5"
  if [[ "$DESTRUCTIVE_WINDOW_ACTIVE" -eq 1 ]]; then
    echo "[DRY-RUN] defer Docker restart until the destructive storage window closes; Docker is intentionally held down and will be started after the SSD is ready"
  else
    echo "[DRY-RUN] systemctl restart docker"
  fi
else
  mkdir -p /etc/docker
  if [[ -f "$DOCKER_DAEMON_JSON" ]]; then
    m1s_backup_file_with_retention "$DOCKER_DAEMON_JSON" '.bak' '+%s'
  fi
  cat > "$DOCKER_DAEMON_JSON" <<'DOCKER_JSON'
{
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "10m",
    "max-file": "5"
  }
}
DOCKER_JSON
  chmod 0644 "$DOCKER_DAEMON_JSON"
  if [[ "$DESTRUCTIVE_WINDOW_ACTIVE" -eq 1 ]]; then
    info "Wrote $DOCKER_DAEMON_JSON; Docker restart is deferred until the destructive storage window closes because Docker is intentionally held down and will be started after the SSD is ready"
  else
    systemctl restart docker || warn "Failed to restart docker after $DOCKER_DAEMON_JSON update"
    info "Wrote $DOCKER_DAEMON_JSON and restarted docker"
  fi
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
fi
leave_destructive_storage_window
run_cmd systemctl enable --now fullnode-mount-guard.timer

ensure_host_data_alias() {
  if [[ "$DRY_RUN" -eq 1 ]]; then
    echo "[DRY-RUN] create $HOST_DATA_ALIAS as a bind alias for $DATA_DIR"
    echo "[DRY-RUN] rewrite $HOST_DATA_ALIAS fstab entries after the $DATA_DIR mount entry"
    echo "[DRY-RUN] unmount any stale $HOST_DATA_ALIAS bind layers before remounting"
    return 0
  fi

  findmnt -M "$DATA_DIR" >/dev/null 2>&1 || { err "$DATA_DIR is not mounted; refusing to create $HOST_DATA_ALIAS alias."; exit 1; }

  if [[ -L "$HOST_DATA_ALIAS" ]]; then
    err "$HOST_DATA_ALIAS is a symlink; refusing to use it for Umbrel data. A real bind mount is required."
    exit 1
  fi

  if [[ -e "$HOST_DATA_ALIAS" && ! -d "$HOST_DATA_ALIAS" ]]; then
    err "$HOST_DATA_ALIAS exists but is not a directory; refusing to replace it."
    exit 1
  fi

  if [[ -d "$HOST_DATA_ALIAS" ]] && ! findmnt --target "$HOST_DATA_ALIAS" >/dev/null 2>&1; then
    if find "$HOST_DATA_ALIAS" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null | grep -q .; then
      err "$HOST_DATA_ALIAS exists and is not empty while not mounted. Refusing to hide unrelated files."
      exit 1
    fi
  fi

  m1s_backup_file_with_retention /etc/fstab '.bak.data-alias' '+%Y%m%d%H%M%S'
  HOST_DATA_ALIAS="$HOST_DATA_ALIAS" DATA_DIR="$DATA_DIR" DATA_ALIAS_FSTAB_OPTIONS="$DATA_ALIAS_FSTAB_OPTIONS" python3 - <<'PY'
from pathlib import Path
import os

fstab = Path('/etc/fstab')
alias = os.environ['HOST_DATA_ALIAS']
data_dir = os.environ['DATA_DIR']
options = os.environ['DATA_ALIAS_FSTAB_OPTIONS']
entry = f'{data_dir}\t{alias}\tnone\t{options}\t0\t0'
lines = fstab.read_text().splitlines()
filtered = []
for line in lines:
    stripped = line.strip()
    if not stripped or stripped.startswith('#'):
        filtered.append(line)
        continue
    parts = stripped.split()
    if len(parts) >= 2 and parts[1] == alias:
        continue
    filtered.append(line)
filtered.append(entry)
fstab.write_text('\n'.join(filtered).rstrip() + '\n')
PY
  systemctl daemon-reload || true

  mkdir -p "$HOST_DATA_ALIAS"
  while findmnt -rn -M "$HOST_DATA_ALIAS" >/dev/null 2>&1; do
    umount "$HOST_DATA_ALIAS"
  done
  mount --bind "$DATA_DIR" "$HOST_DATA_ALIAS"

  if [[ "$(stat -c '%d:%i' "$HOST_DATA_ALIAS")" != "$(stat -c '%d:%i' "$DATA_DIR")" ]]; then
    err "$HOST_DATA_ALIAS bind mount does not match $DATA_DIR after mount."
    exit 1
  fi
}

run_cmd systemctl enable docker
run_cmd systemctl start docker

ensure_host_data_alias

if [[ -n "${SUDO_USER:-}" && "${SUDO_USER}" != "root" ]]; then
  run_cmd usermod -aG docker "$SUDO_USER"
fi

info "Pulling and starting Umbrel"
pull_and_verify_umbrel_image
run_shell "docker rm -f umbrel >/dev/null 2>&1 || true"
# Note: --privileged and docker.sock mount are required by the dockurr/umbrel image
# to manage its internal Docker containers. --pid=host is required for process management.
run_cmd docker run -d --name umbrel --restart always -p 80:80 -v "$HOST_DATA_ALIAS:/data" -v /var/run/docker.sock:/var/run/docker.sock --stop-timeout 60 --pid=host --privileged "$IMAGE"

if [[ "$DRY_RUN" -eq 0 ]]; then
  info "Waiting for Umbrel container to stabilize..."
  if ! wait_for_umbrel_container; then
    CONTAINER_STATE="$(docker inspect --format='{{.State.Status}}' umbrel 2>/dev/null || true)"
    err "Umbrel container failed to start (state: ${CONTAINER_STATE:-unknown})."
    err "The SSD is mounted at $DATA_DIR and Docker is installed, but the install cannot be marked successful until Umbrel is running."
    err "Check logs with: sudo docker logs umbrel"
    err "After fixing the cause, retry Umbrel manually:"
    err "  sudo docker rm -f umbrel; sudo docker run -d --name umbrel --restart always -p 80:80 -v $HOST_DATA_ALIAS:/data -v /var/run/docker.sock:/var/run/docker.sock --stop-timeout 60 --pid=host --privileged $IMAGE"
    exit 1
  else
    info "Umbrel container is running."
    install_umbrel_safe_shutdown || exit 1
  fi
else
  install_umbrel_safe_shutdown || exit 1
fi

info "Setting host hostname to umbrel (for native mDNS stability)"
UMBREL_HOSTNAME="umbrel"
if [[ "$DRY_RUN" -eq 1 ]]; then
  echo "[DRY-RUN] hostnamectl set-hostname $UMBREL_HOSTNAME"
  echo "[DRY-RUN] update /etc/hosts 127.0.1.1 line to $UMBREL_HOSTNAME"
else
  CURRENT_HN="$(hostnamectl --static 2>/dev/null || hostname)"
  if [[ "$CURRENT_HN" != "$UMBREL_HOSTNAME" ]]; then
    hostnamectl set-hostname "$UMBREL_HOSTNAME" || warn "hostnamectl set-hostname failed (continuing)"
    if grep -qE '^127\.0\.1\.1[[:space:]]' /etc/hosts; then
      sed -i "s/^127\.0\.1\.1[[:space:]].*/127.0.1.1\t$UMBREL_HOSTNAME/" /etc/hosts
    else
      printf '127.0.1.1\t%s\n' "$UMBREL_HOSTNAME" >> /etc/hosts
    fi
    info "Hostname set to $UMBREL_HOSTNAME (was: $CURRENT_HN)"
  else
    info "Hostname already $UMBREL_HOSTNAME; skipping"
  fi
fi

info "Setting up umbrel.local mDNS alias"
LAN_INTERFACE="$(detect_lan_interface || true)"
LAN_IP="$(m1s_interface_ipv4 "$LAN_INTERFACE" || true)"
disable_ufw_for_umbrel

if ! command -v avahi-publish >/dev/null 2>&1; then
  info "Installing avahi-daemon and avahi-utils..."
  if [[ "$DRY_RUN" -eq 0 ]]; then
    if ! DEBIAN_FRONTEND=noninteractive apt-get install -y avahi-daemon avahi-utils libnss-mdns >/dev/null 2>&1; then
      err "Failed to install avahi-daemon, avahi-utils, and libnss-mdns."
      exit 1
    fi
  else
    run_shell 'DEBIAN_FRONTEND=noninteractive apt-get install -y avahi-daemon avahi-utils libnss-mdns'
  fi
fi

if ! m1s_configure_avahi_mdns; then
  err "Failed to configure the managed umbrel.local mDNS path."
  exit 1
fi

if [[ "$DRY_RUN" -eq 0 ]]; then
  info "umbrel.local mDNS alias is now active."
  if ! wait_for_umbrel_runtime_health; then
    err "The install cannot be marked successful until the full Umbrel runtime-health contract passes."
    exit 1
  fi
  report_install_health "$LAN_INTERFACE" "$LAN_IP"
fi

info "Recording install state"
if [[ "$DRY_RUN" -eq 1 ]]; then
  echo "[DRY-RUN] write $INSTALL_STATE_FILE (version=$INSTALL_STATE_VERSION)"
else
  record_install_state || exit 1
  info "Install state written to $INSTALL_STATE_FILE (version=$INSTALL_STATE_VERSION)"
fi

clear_preinstall_resume_state

info "Done."
cat <<EOF

Umbrel container has been started.
Open: http://umbrel.local  or  http://${LAN_IP:-<device-ip>}
Tailscale app: http://${LAN_IP:-<device-ip>}:8240
Image: $IMAGE
Data directory: $DATA_DIR
LAN interface: ${LAN_INTERFACE:-unknown}
LAN IP: ${LAN_IP:-unknown}
Script version: $SCRIPT_VERSION

If you used --dry-run, no changes were made.
If Docker group membership was updated for your user, log out and back in before using docker without sudo.
EOF
