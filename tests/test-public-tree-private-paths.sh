#!/usr/bin/env bash
set -Eeuo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TEST_TMPDIR"' EXIT

fail() {
  printf '[unit][FAIL] %s\n' "$1" >&2
  exit 1
}

pass() {
  printf '[unit][PASS] %s\n' "$1"
}

assert_eq() {
  [[ "$1" == "$2" ]] || fail "$3: expected '$1', got '$2'"
}

assert_contains() {
  [[ "$1" == *"$2"* ]] || fail "$3: missing '$2'"
}

run_guard() {
  (
    cd "$fixture_root"
    # shellcheck source=scripts/public-tree-private-paths.sh
    source "$repo_root/scripts/public-tree-private-paths.sh"
    public_tree_require_no_ignored_paths
  )
}

assert_guard_rejects() {
  local label="$1"
  local expected_path="$2"
  local output=""
  local status=0

  set +e
  output="$(run_guard 2>&1)"
  status=$?
  set -e

  assert_eq '1' "$status" "$label should refuse the public tree"
  assert_contains "$output" 'Refusing to publish: current tree contains paths matching .gitignore' "$label should name the ignore-rule gate"
  assert_contains "$output" "$expected_path" "$label should name the matching path"
}

fixture_root="$TEST_TMPDIR/public-tree"
mkdir -p "$fixture_root"
(
  cd "$fixture_root"
  git init -q
  git config user.email 'fixture@example.invalid'
  git config user.name 'Fixture'
  mkdir -p docs/private
  printf '/AGENTS.md\n/docs/private/\n/.local/\n' > .gitignore
  printf 'public fixture\n' > public.txt
  git add .gitignore public.txt
  git commit -qm 'Create legitimate public tree'
)

printf '[unit] legitimate public tree passes the derived ignore-rule guard\n'
legitimate_output="$(run_guard)"
assert_contains "$legitimate_output" '[public-tree] no paths matching .gitignore found in HEAD' 'legitimate public tree should pass'
pass 'legitimate public tree passes'

(
  cd "$fixture_root"
  printf 'private fixture\n' > AGENTS.md
  git add -f AGENTS.md
  git commit -qm 'Track ignored operating document'
)

printf '[unit] tracked ignored paths require --no-index to be visible\n'
set +e
default_output="$(cd "$fixture_root" && git ls-tree -r --name-only HEAD | git check-ignore --stdin)"
default_status=$?
set -e
assert_eq '1' "$default_status" 'default check-ignore should skip tracked ignored paths'
assert_eq '' "$default_output" 'default check-ignore should emit no tracked ignored path'
pass 'tracked ignored paths are invisible without --no-index'

printf '[unit] tracked ignored operating document is rejected\n'
assert_guard_rejects 'tracked ignored operating document' 'AGENTS.md'
pass 'tracked ignored operating document is rejected'

(
  cd "$fixture_root"
  git rm -q AGENTS.md
  git commit -qm 'Remove ignored operating document'
  printf 'private fixture\n' > docs/private/note.txt
  git add -f docs/private/note.txt
  git commit -qm 'Track ignored private note'
)

printf '[unit] tracked ignored private directory path is rejected\n'
assert_guard_rejects 'tracked ignored private directory path' 'docs/private/note.txt'
pass 'tracked ignored private directory path is rejected'

printf '[unit] public tree ignore-rule guard tests complete\n'
