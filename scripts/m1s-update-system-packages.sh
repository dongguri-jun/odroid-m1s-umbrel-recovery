#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_VERSION="0.5.30"
DRY_RUN=0
NO_REBOOT=0
STOP_TIMEOUT_SECONDS=300
APT_LOCK_TIMEOUT_SECONDS=300
UMBREL_MANAGED_CONTAINER_WAIT_ATTEMPTS="${UMBREL_MANAGED_CONTAINER_WAIT_ATTEMPTS:-30}"
UMBREL_MANAGED_CONTAINER_WAIT_DELAY_SECONDS="${UMBREL_MANAGED_CONTAINER_WAIT_DELAY_SECONDS:-2}"
STOPPED_CONTAINERS=()
STOPPED_UMBREL_MANAGED_CONTAINERS=()
STOPPED_INDEPENDENT_CONTAINERS=()
CONTAINER_OWNERSHIP_CAPTURED=0
CONTAINERS_STOPPED=0
REBOOTING=0

# shellcheck source=scripts/m1s-support-policy.sh
source "$(dirname "${BASH_SOURCE[0]}")/m1s-support-policy.sh"
# shellcheck source=scripts/m1s-docker-lifecycle.sh
source "$(dirname "${BASH_SOURCE[0]}")/m1s-docker-lifecycle.sh"

usage() {
  cat <<'EOF'
ODROID M1S Umbrel — update Ubuntu packages safely

Usage:
  sudo bash scripts/m1s-update-system-packages.sh [options]

Options:
  --dry-run      Show what would run without changing packages, containers, or rebooting.
  --no-reboot    Do not reboot automatically; restart containers if a reboot is required.
  --version      Print script version and exit.
  -h, --help     Show this help.

This helper is for Ubuntu/security/kernel-adjacent package updates. It stops
running Docker containers before apt upgrade, then either reboots if required or
starts the containers again when no reboot is needed.
EOF
}

log() {
  printf '[%s] %s\n' "$1" "$2"
}

info() { log INFO "$1"; }
warn() { log WARN "$1"; }
err() { log ERROR "$1" >&2; }

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --dry-run)
        DRY_RUN=1
        ;;
      --no-reboot)
        NO_REBOOT=1
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
        usage >&2
        exit 2
        ;;
    esac
    shift
  done
}

require_root() {
  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    err "Run with sudo: sudo bash scripts/m1s-update-system-packages.sh"
    exit 1
  fi
}

require_cmd() {
  local cmd="$1"
  command -v "$cmd" >/dev/null 2>&1 || { err "Missing required command: $cmd"; exit 1; }
}

print_command() {
  printf '[DRY-RUN]'
  for arg in "$@"; do
    printf ' %q' "$arg"
  done
  printf '\n'
}

run_cmd() {
  if [[ "$DRY_RUN" -eq 1 ]]; then
    print_command "$@"
    return 0
  fi
  "$@"
}

run_noninteractive() {
  if [[ "$DRY_RUN" -eq 1 ]]; then
    print_command env DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a APT_LISTCHANGES_FRONTEND=none "$@"
    return 0
  fi
  DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a APT_LISTCHANGES_FRONTEND=none "$@"
}

apt_get_command() {
  run_noninteractive apt-get -o DPkg::Lock::Timeout="$APT_LOCK_TIMEOUT_SECONDS" "$@"
}

apt_update_command() {
  apt_get_command update
}

apt_upgrade_command() {
  apt_get_command \
    -o Dpkg::Options::=--force-confdef \
    -o Dpkg::Options::=--force-confold \
    upgrade -y
}

dpkg_configure_command() {
  run_noninteractive \
    dpkg \
    --force-confdef \
    --force-confold \
    --configure -a
}

apt_fix_install_command() {
  apt_get_command \
    -o Dpkg::Options::=--force-confdef \
    -o Dpkg::Options::=--force-confold \
    -f install -y
}

apt_check_command() {
  apt_get_command check
}

apt_clean_command() {
  apt_get_command clean
}

clean_apt_cache() {
  info "Cleaning apt package cache to preserve eMMC root space..."
  apt_clean_command || warn "apt-get clean failed; continuing because package update and apt check already succeeded."
}

load_running_containers() {
  m1s_docker_lifecycle_load_running STOPPED_CONTAINERS
  classify_stopped_containers
  CONTAINER_OWNERSHIP_CAPTURED=1
}

classify_stopped_containers() {
  local container

  STOPPED_UMBREL_MANAGED_CONTAINERS=()
  STOPPED_INDEPENDENT_CONTAINERS=()
  for container in "${STOPPED_CONTAINERS[@]}"; do
    if is_umbrel_managed_container "$container"; then
      STOPPED_UMBREL_MANAGED_CONTAINERS+=("$container")
    elif [[ "$container" != "umbrel" ]]; then
      STOPPED_INDEPENDENT_CONTAINERS+=("$container")
    fi
  done
}

is_umbrel_managed_container() {
  local container="$1"
  local compose_working_dir

  compose_working_dir="$(docker inspect "$container" --format '{{index .Config.Labels "com.docker.compose.project.working_dir"}}' 2>/dev/null || true)"
  [[ "$compose_working_dir" == /opt/umbreld/source/modules/* ]]
}

stopped_umbrel_parent() {
  local container
  for container in "${STOPPED_CONTAINERS[@]}"; do
    [[ "$container" == "umbrel" ]] && return 0
  done
  return 1
}

wait_for_umbrel_managed_containers() {
  local attempt container state
  local all_running

  [[ "${#STOPPED_UMBREL_MANAGED_CONTAINERS[@]}" -gt 0 ]] || return 0
  for ((attempt = 1; attempt <= UMBREL_MANAGED_CONTAINER_WAIT_ATTEMPTS; attempt++)); do
    all_running=1
    for container in "${STOPPED_UMBREL_MANAGED_CONTAINERS[@]}"; do
      state="$(docker inspect "$container" --format '{{.State.Status}}' 2>/dev/null || true)"
      if [[ "$state" != "running" ]]; then
        all_running=0
        break
      fi
    done
    [[ "$all_running" -eq 1 ]] && return 0
    if [[ "$attempt" -lt "$UMBREL_MANAGED_CONTAINER_WAIT_ATTEMPTS" ]]; then
      sleep "$UMBREL_MANAGED_CONTAINER_WAIT_DELAY_SECONDS"
    fi
  done
  err "Umbrel-managed containers did not return running after $UMBREL_MANAGED_CONTAINER_WAIT_ATTEMPTS attempts."
  return 1
}

print_bitcoin_container_hint() {
  command -v docker >/dev/null 2>&1 || return 0
  local bitcoin_containers
  bitcoin_containers="$(docker ps --format '{{.Names}} {{.Status}}' 2>/dev/null | grep -Ei 'bitcoin|electrs|fulcrum|mempool' || true)"
  if [[ -n "$bitcoin_containers" ]]; then
    warn "Bitcoin-related containers are running and will be stopped gracefully before the system update:"
    printf '%s\n' "$bitcoin_containers" | sed 's/^/[WARN]   /'
  else
    info "No Bitcoin app container is currently visible in host Docker."
  fi
}

stop_running_containers() {
  if [[ "${#STOPPED_CONTAINERS[@]}" -eq 0 ]]; then
    info "No running Docker containers to stop."
    return 0
  fi

  info "Stopping running Docker containers before apt upgrade (${#STOPPED_CONTAINERS[@]} container(s), timeout ${STOP_TIMEOUT_SECONDS}s)..."
  CONTAINERS_STOPPED=1
  if m1s_docker_lifecycle_stop STOPPED_CONTAINERS "$STOP_TIMEOUT_SECONDS"; then
    return 0
  else
    local status=$?
    warn "Docker stop failed; attempting to restart any containers that were already stopped."
    start_stopped_containers || warn "Failed to restart containers after docker stop failure; check Docker manually."
    return "$status"
  fi
}

start_stopped_containers() {
  if [[ "$CONTAINERS_STOPPED" -ne 1 || "${#STOPPED_CONTAINERS[@]}" -eq 0 ]]; then
    return 0
  fi

  if [[ "$CONTAINER_OWNERSHIP_CAPTURED" -ne 1 ]]; then
    classify_stopped_containers
  fi
  info "Starting containers again because no reboot is being performed..."
  if [[ "$DRY_RUN" -eq 1 ]]; then
    run_cmd docker start "${STOPPED_CONTAINERS[@]}"
    CONTAINERS_STOPPED=0
    CONTAINER_OWNERSHIP_CAPTURED=0
    return 0
  fi

  if [[ "${#STOPPED_UMBREL_MANAGED_CONTAINERS[@]}" -gt 0 ]]; then
    if ! stopped_umbrel_parent; then
      err "Umbrel-managed containers were stopped but the top-level umbrel container was not captured for recovery."
      return 1
    fi
    docker start umbrel >/dev/null || {
      err "Failed to restart the top-level umbrel container."
      return 1
    }
    wait_for_umbrel_managed_containers || return 1
  elif stopped_umbrel_parent; then
    STOPPED_INDEPENDENT_CONTAINERS+=(umbrel)
  fi

  m1s_docker_lifecycle_start_existing_reverse STOPPED_INDEPENDENT_CONTAINERS || return 1
  CONTAINERS_STOPPED=0
  CONTAINER_OWNERSHIP_CAPTURED=0
}

reboot_required() {
  [[ -f /var/run/reboot-required ]]
}

print_reboot_required_status() {
  if reboot_required; then
    warn "System reports that a reboot is required."
    if [[ -f /var/run/reboot-required.pkgs ]]; then
      warn "Packages requesting reboot:"
      sed 's/^/[WARN]   /' /var/run/reboot-required.pkgs || true
    fi
  else
    info "No reboot is required after this package update."
  fi
}

on_error() {
  local status=$?
  err "System package update failed with exit code $status."
  if [[ "$REBOOTING" -ne 1 ]]; then
    start_stopped_containers || warn "Failed to restart containers after the error; check Docker manually."
  fi
  exit "$status"
}

main() {
  parse_args "$@"
  m1s_report_host_support
  require_root
  require_cmd apt-get

  trap on_error ERR

  info "Script version: $SCRIPT_VERSION"
  info "Updating apt package lists before stopping containers..."
  apt_update_command

  if command -v docker >/dev/null 2>&1; then
    print_bitcoin_container_hint
    load_running_containers
    stop_running_containers
  else
    warn "Docker is not installed or not in PATH; continuing with package update only."
  fi

  info "Applying Ubuntu package upgrades with noninteractive config-file defaults..."
  apt_upgrade_command

  info "Repairing any pending package configuration..."
  dpkg_configure_command
  apt_fix_install_command
  apt_check_command
  clean_apt_cache

  print_reboot_required_status

  if reboot_required; then
    if [[ "$NO_REBOOT" -eq 1 ]]; then
      warn "--no-reboot specified; restarting containers and leaving reboot to the operator."
      start_stopped_containers
      exit 0
    fi

    warn "Rebooting now so kernel/system package changes can take effect."
    if run_cmd systemctl reboot; then
      REBOOTING=1
      exit 0
    else
      status=$?
      err "Reboot command failed with exit code $status; restarting containers instead."
      start_stopped_containers || warn "Failed to restart containers after reboot command failure; check Docker manually."
      exit "$status"
    fi
  fi

  start_stopped_containers
  info "System package update complete."
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
