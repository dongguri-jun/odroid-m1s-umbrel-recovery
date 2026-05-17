#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_VERSION="0.5.10"
DRY_RUN=0

usage() {
  cat <<'EOF'
ODROID M1S Umbrel — start Bitcoin chainstate rebuild

Usage:
  sudo bash scripts/m1s-start-bitcoin-chainstate-rebuild.sh [options]

Options:
  --dry-run      Show actions without changing anything.
  --version      Print script version and exit.
  -h, --help     Show this help.

After this command finishes, monitor the result with:
  sudo bash scripts/m1s-check-bitcoin-recovery-status.sh
EOF
}

parse_args() {
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
}

# shellcheck source=scripts/bitcoin-recovery-common.sh
source "$(dirname "${BASH_SOURCE[0]}")/bitcoin-recovery-common.sh"

main() {
  parse_args "$@"
  run_recovery_start "chainstate-rebuild" "m1s-start-bitcoin-chainstate-rebuild.sh"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
