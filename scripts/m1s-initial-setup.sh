#!/usr/bin/env bash
set -Eeuo pipefail

# ODROID M1S Initial Setup
# Run after Umbrel install: create a new user and keep hostname fixed to umbrel
#
# Usage:
#   sudo bash m1s-initial-setup.sh
#   sudo bash m1s-initial-setup.sh --dry-run
#   sudo bash m1s-initial-setup.sh --version

SCRIPT_VERSION="0.5.20"
DRY_RUN=0
FIXED_HOSTNAME="umbrel"
HOSTS_FILE="${HOSTS_FILE:-/etc/hosts}"

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

update_fixed_hostname_hosts() {
  local current_hostname="$1"
  local fixed_hostname="$2"

  if [[ "$DRY_RUN" -eq 1 ]]; then
    echo "[DRY-RUN] $HOSTS_FILE: ensure 127.0.1.1 maps to '$fixed_hostname'"
    return 0
  fi

  if grep -qE '^127\.0\.1\.1[[:space:]]' "$HOSTS_FILE"; then
    sed -i "s/^127\.0\.1\.1[[:space:]].*/127.0.1.1\t$fixed_hostname/" "$HOSTS_FILE"
  else
    printf '127.0.1.1\t%s\n' "$fixed_hostname" >> "$HOSTS_FILE"
  fi

  # If the old hostname was present only as a secondary alias on a different line,
  # leave it alone. This helper owns only the Debian-style 127.0.1.1 host entry.
  : "$current_hostname"
}

usage() {
  cat <<'EOF'
ODROID M1S Initial Setup - create a new user

Usage:
  sudo bash m1s-initial-setup.sh [options]

Options:
  --dry-run    Show actions without changing anything
  --version    Print script version and exit
  -h, --help   Show this help

Run this script after m1s-clean-install-umbrel.sh finishes.

What this script does:
  1. Creates a new user account and grants sudo/docker permissions.
  2. Keeps the hostname fixed to umbrel for http://umbrel.local access.
  3. Tells you how to log in again and remove the old account if needed.
EOF
}

main() {
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

  if [[ "${EUID}" -ne 0 ]]; then
    err "Run this script with sudo or as root."
    err "Example: sudo bash m1s-initial-setup.sh"
    exit 1
  fi

  local current_user="${SUDO_USER:-}"
  if [[ -z "$current_user" || "$current_user" == "root" ]]; then
    err "Run this through sudo. Example: sudo bash m1s-initial-setup.sh"
    err "The current user cannot be detected when logged in directly as root."
    exit 1
  fi

  local current_hostname
  current_hostname="$(hostname)"

  echo
  echo "=== ODROID M1S Initial Setup ==="
  echo "Current user:     $current_user"
  echo "Current hostname: $current_hostname"
  echo

  local new_user=""
  local new_pass=""
  local new_pass_confirm=""
  local confirm=""

  # Step 1: new username
  while true; do
    read -r -p "Enter new username: " new_user

    if [[ -z "$new_user" ]]; then
      warn "Enter a username."
      continue
    fi

    # Validate Linux username: lowercase letters, numbers, hyphen, underscore
    if [[ ! "$new_user" =~ ^[a-z_][a-z0-9_-]*$ ]]; then
      warn "Username may only use lowercase letters, numbers, hyphen (-), and underscore (_)."
      warn "The first character must be a lowercase letter or underscore."
      continue
    fi

    if [[ ${#new_user} -gt 32 ]]; then
      warn "Username must be 32 characters or shorter."
      continue
    fi

    if [[ "$new_user" == "$current_user" ]]; then
      warn "'$new_user' is the current account. Enter a different username."
      continue
    fi

    if id "$new_user" >/dev/null 2>&1; then
      warn "Account '$new_user' already exists. Enter a different username."
      continue
    fi

    break
  done

  # Step 2: password
  while true; do
    read -r -s -p "New password: " new_pass
    echo

    if [[ -z "$new_pass" ]]; then
      warn "Enter a password."
      continue
    fi

    if [[ ${#new_pass} -lt 4 ]]; then
      warn "Password must be at least 4 characters."
      continue
    fi

    read -r -s -p "Confirm password: " new_pass_confirm
    echo

    if [[ "$new_pass" != "$new_pass_confirm" ]]; then
      warn "Passwords do not match. Try again."
      continue
    fi

    break
  done

  # Step 3: summary and confirmation
  echo
  echo "=== Change summary ==="
  echo "New user:         $new_user"
  echo "Hostname:         $FIXED_HOSTNAME (fixed for umbrel.local)"
  echo "Current user:     $current_user (not removed now)"
  echo

  if [[ "$DRY_RUN" -eq 1 ]]; then
    echo "[DRY-RUN mode] No real changes will be made."
    echo
  fi

  read -r -p "Continue? [y/N]: " confirm
  if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
    echo "Cancelled."
    exit 0
  fi

  echo

  # Step 4: create new user
  info "Creating new user '$new_user'..."
  run_cmd useradd -m -s /bin/bash "$new_user"

  info "Setting password..."
  if [[ "$DRY_RUN" -eq 1 ]]; then
    echo "[DRY-RUN] chpasswd (password hidden)"
  else
    printf '%s:%s\n' "$new_user" "$new_pass" | chpasswd
  fi

  info "Adding user to sudo group..."
  run_cmd usermod -aG sudo "$new_user"

  if getent group docker >/dev/null 2>&1; then
    info "Adding user to docker group..."
    run_cmd usermod -aG docker "$new_user"
  fi

  # Step 5: keep hostname fixed for umbrel.local
  if [[ "$FIXED_HOSTNAME" != "$current_hostname" ]]; then
    info "Setting hostname to '$FIXED_HOSTNAME' for umbrel.local access..."
    run_cmd hostnamectl set-hostname "$FIXED_HOSTNAME"
  else
    info "Hostname is already '$FIXED_HOSTNAME'. No change needed."
  fi
  update_fixed_hostname_hosts "$current_hostname" "$FIXED_HOSTNAME"

  # Step 6: completion guidance
  echo
  echo "========================================="
  echo "  Initial setup complete!"
  echo "========================================="
  echo
  echo "New account '$new_user' was created."
  echo "Hostname: $FIXED_HOSTNAME"
  echo
  echo "Next steps:"
  echo "  1. Log out now: exit"
  echo "  2. Log in again as the new user: $new_user"
  echo "  3. To remove the old account '$current_user', run:"
  echo
  echo "     sudo userdel -r $current_user"
  echo
  echo "  Warning: this also deletes the old home directory (/home/$current_user)."
  echo "  Copy any needed files before deleting the old account."
  echo
  if [[ "$DRY_RUN" -eq 1 ]]; then
    echo "[DRY-RUN] This was only a simulation. No real changes were made."
  fi
}

if [[ "${M1S_INITIAL_SETUP_LIB_ONLY:-0}" != "1" ]]; then
  main "$@"
fi
