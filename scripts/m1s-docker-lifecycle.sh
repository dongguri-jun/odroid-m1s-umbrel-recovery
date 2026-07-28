#!/usr/bin/env bash

m1s_docker_lifecycle_load_running() {
  local containers_name="$1"
  local predicate_name="${2:-}"
  local container
  # shellcheck disable=SC2178
  local -n containers_ref="$containers_name"

  containers_ref=()
  command -v docker >/dev/null 2>&1 || return 0
  while IFS= read -r container; do
    [[ -n "$container" ]] || continue
    if [[ -n "$predicate_name" ]] && ! "$predicate_name" "$container"; then
      continue
    fi
    containers_ref+=("$container")
  done < <(docker ps --format '{{.Names}}' 2>/dev/null || true)
}

m1s_docker_lifecycle_stop() {
  local containers_name="$1"
  local timeout_seconds="$2"
  # shellcheck disable=SC2178
  local -n containers_ref="$containers_name"

  [[ "${#containers_ref[@]}" -gt 0 ]] || return 0
  run_cmd docker stop --timeout "$timeout_seconds" "${containers_ref[@]}"
}

m1s_docker_lifecycle_start_existing_reverse() {
  local containers_name="$1"
  # shellcheck disable=SC2178
  local -n containers_ref="$containers_name"
  local container index
  local failed=0

  for ((index=${#containers_ref[@]} - 1; index >= 0; index--)); do
    container="${containers_ref[$index]}"
    if ! docker container inspect "$container" >/dev/null 2>&1; then
      warn "Container $container no longer exists; skipping direct restart."
      continue
    fi
    if ! docker start "$container" >/dev/null; then
      warn "Failed to restart container: $container"
      failed=1
    fi
  done
  return "$failed"
}
