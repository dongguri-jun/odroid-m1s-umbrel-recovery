#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_VERSION="0.5.17"

usage() {
  cat <<'EOF'
ODROID M1S Umbrel — compatibility wrapper for Bitcoin chainstate rebuild

This command has been replaced by:
  sudo bash scripts/m1s-start-bitcoin-chainstate-rebuild.sh

Public flow:
  1. sudo bash scripts/m1s-start-bitcoin-chainstate-rebuild.sh
  2. sudo bash scripts/m1s-check-bitcoin-chainstate-rebuild.sh
EOF
}

main() {
  if [[ $# -gt 0 ]]; then
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
        printf '[WARN] scripts/m1s-request-bitcoin-chainstate-rebuild.sh is deprecated.\n' >&2
        printf '[WARN] Forwarding to scripts/m1s-start-bitcoin-chainstate-rebuild.sh\n' >&2
        ;;
    esac
  fi

  exec bash "$(dirname "${BASH_SOURCE[0]}")/m1s-start-bitcoin-chainstate-rebuild.sh" "$@"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
