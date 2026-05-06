#!/usr/bin/env bash
set -Eeuo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

require_cmd() {
  local cmd="$1"
  if ! command -v "$cmd" >/dev/null 2>&1; then
    printf 'Missing required command: %s\n' "$cmd" >&2
    exit 1
  fi
}

require_cmd git

if [[ "$(git rev-parse --is-inside-work-tree 2>/dev/null || true)" != "true" ]]; then
  printf 'This script must run from a Git working tree.\n' >&2
  exit 1
fi

if [[ ! -x .githooks/pre-push ]]; then
  printf 'Git pre-push hook is missing or not executable: .githooks/pre-push\n' >&2
  exit 1
fi

git config --local core.hooksPath .githooks

if git config --local --get-regexp '^branch\.public-clean\.(remote|merge)$' >/dev/null 2>&1; then
  git branch --unset-upstream public-clean 2>/dev/null || true
fi

printf '[guard] installed core.hooksPath=.githooks\n'
printf '[guard] local public-clean upstream is unset\n'
printf '[guard] allowed publish command: git push origin public-clean:main\n'
