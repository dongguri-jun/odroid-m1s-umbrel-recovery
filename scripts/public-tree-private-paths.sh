#!/usr/bin/env bash

public_tree_require_no_ignored_paths() {
  local treeish="${1:-HEAD}"
  local tree_hash=""
  local path=""
  local check_status=0
  local -a ignored_paths=()

  tree_hash="$(git rev-parse --verify "${treeish}^{tree}")" || {
    printf '[public-tree] Cannot resolve the tree to inspect: %s\n' "$treeish" >&2
    return 1
  }

  while IFS= read -r -d '' path; do
    if git check-ignore --no-index -q -- "$path"; then
      ignored_paths+=("$path")
      continue
    else
      check_status=$?
      if [[ "$check_status" -ne 1 ]]; then
        printf '[public-tree] Cannot evaluate .gitignore for path: %s\n' "$path" >&2
        return 1
      fi
    fi
  done < <(git ls-tree -r -z --name-only "$tree_hash")

  if [[ "${#ignored_paths[@]}" -gt 0 ]]; then
    printf '[public-tree] Refusing to publish: current tree contains paths matching .gitignore:\n' >&2
    printf '  %s\n' "${ignored_paths[@]}" >&2
    return 1
  fi

  printf '[public-tree] no paths matching .gitignore found in %s\n' "$treeish"
}
