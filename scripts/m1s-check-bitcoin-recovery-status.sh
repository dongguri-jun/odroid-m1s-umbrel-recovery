#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_VERSION="0.5.10"

usage() {
  cat <<'EOF'
ODROID M1S Umbrel — check Bitcoin recovery status

Usage:
  sudo bash scripts/m1s-check-bitcoin-recovery-status.sh [options]

Options:
  --version      Print script version and exit.
  -h, --help     Show this help.
EOF
}

parse_args() {
  [[ $# -eq 0 ]] && return 0
  if [[ $# -gt 1 ]]; then
    err "This script does not accept positional arguments or combined flags."
    usage
    exit 1
  fi

  case "$1" in
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
}

# shellcheck source=scripts/bitcoin-recovery-common.sh
source "$(dirname "${BASH_SOURCE[0]}")/bitcoin-recovery-common.sh"

main() {
  parse_args "$@"
  run_recovery_status_check
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
