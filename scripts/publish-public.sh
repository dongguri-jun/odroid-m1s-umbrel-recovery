#!/usr/bin/env bash
set -Eeuo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

dry_run=0

usage() {
  cat <<'USAGE'
Usage: bash scripts/publish-public.sh [--dry-run]

Safely publishes the local public-clean branch to the remote main branch.

This script refuses to publish unless:
  - the current branch is public-clean,
  - the working tree is clean,
  - local public-clean has no upstream,
  - origin/main exists,
  - origin/public-clean does not exist.

It only pushes with this explicit refspec:
  git push origin public-clean:main
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)
      dry_run=1
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      printf 'Unknown argument: %s\n' "$1" >&2
      usage >&2
      exit 2
      ;;
  esac
  shift
done

require_cmd() {
  local cmd="$1"
  if ! command -v "$cmd" >/dev/null 2>&1; then
    printf 'Missing required command: %s\n' "$cmd" >&2
    exit 1
  fi
}

require_cmd git

current_branch="$(git branch --show-current)"
head_sha="$(git rev-parse HEAD)"

printf '[publish] branch %s\n' "$current_branch"
printf '[publish] HEAD %s\n' "$head_sha"

if [[ "$current_branch" != "public-clean" ]]; then
  printf 'Publish must run from public-clean. Current branch: %s\n' "$current_branch" >&2
  exit 1
fi

if ! git diff --quiet || ! git diff --cached --quiet; then
  printf 'Working tree has unstaged or staged changes. Commit before publishing.\n' >&2
  exit 1
fi

if [[ -n "$(git status --porcelain --untracked-files=all)" ]]; then
  printf 'Working tree has untracked files. Commit, ignore, or remove them before publishing.\n' >&2
  git status --short --untracked-files=all >&2
  exit 1
fi

if git rev-parse --abbrev-ref 'public-clean@{upstream}' >/dev/null 2>&1; then
  printf 'Local public-clean must not track an upstream. Run: git branch --unset-upstream public-clean\n' >&2
  exit 1
fi

git fetch origin main --prune >/dev/null
origin_main_sha="$(git rev-parse origin/main)"
printf '[publish] origin/main %s\n' "$origin_main_sha"

if git ls-remote --exit-code --heads origin public-clean >/dev/null 2>&1; then
  printf 'Remote origin/public-clean already exists. Delete it before publishing.\n' >&2
  printf 'Expected only remote main to exist for public publishing.\n' >&2
  exit 1
fi

if [[ "$dry_run" -eq 1 ]]; then
  printf '[publish] dry-run passed. Would run: git push origin public-clean:main\n'
  exit 0
fi

git push origin public-clean:main
printf '[publish] pushed public-clean to origin/main\n'
