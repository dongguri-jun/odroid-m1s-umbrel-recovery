#!/usr/bin/env bash

real_device_validation_main_worktree() {
  local candidate_worktree=""
  local line=""

  while IFS= read -r -d '' line; do
    case "$line" in
      worktree\ *)
        candidate_worktree="${line#worktree }"
        ;;
      'branch refs/heads/main')
        if [[ -n "$candidate_worktree" ]]; then
          printf '%s\n' "$candidate_worktree"
          return 0
        fi
        ;;
    esac
  done < <(git worktree list --porcelain -z)

  printf '[validation] Cannot locate the main worktree from git worktree list.\n' >&2
  return 1
}

real_device_validation_tree_hash() {
  git rev-parse 'HEAD^{tree}'
}

real_device_validation_record_path() {
  local tree_hash="$1"
  local main_worktree

  main_worktree="$(real_device_validation_main_worktree)" || return 1
  printf '%s/.local/real-device-validations/%s.record\n' "$main_worktree" "$tree_hash"
}

real_device_validation_value_is_blank() {
  [[ -z "${1//[[:space:]]/}" ]]
}

real_device_validation_validate_record() {
  local record_path="$1"
  local expected_tree_hash="$2"
  local line key value
  local -A record=()
  local -a required_keys=(
    schema_version
    content_tree
    recorded_at
    user_facing_path_status
    user_facing_path_evidence
    fresh_install_status
    fresh_install_evidence
    official_update_status
    official_update_evidence
    web_ui_status
    web_ui_evidence
    verify_scripts_status
    verify_scripts_evidence
    evidence_for
    evidence_against
    not_confirmed
    honest_caveat
  )
  local check_name

  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ -z "$line" || "$line" == \#* ]]; then
      continue
    fi

    if [[ "$line" != *=* ]]; then
      printf '[validation] Record is malformed: expected key=value.\n' >&2
      return 1
    fi

    key="${line%%=*}"
    value="${line#*=}"
    case "$key" in
      schema_version|content_tree|recorded_at|user_facing_path_status|user_facing_path_evidence|fresh_install_status|fresh_install_evidence|official_update_status|official_update_evidence|web_ui_status|web_ui_evidence|verify_scripts_status|verify_scripts_evidence|evidence_for|evidence_against|not_confirmed|honest_caveat)
        ;;
      *)
        printf '[validation] Record contains an unknown field: %s\n' "$key" >&2
        return 1
        ;;
    esac

    if [[ -n "${record[$key]+present}" ]]; then
      printf '[validation] Record contains a duplicate field: %s\n' "$key" >&2
      return 1
    fi
    record[$key]="$value"
  done < "$record_path"

  for key in "${required_keys[@]}"; do
    if [[ -z "${record[$key]+present}" ]] || real_device_validation_value_is_blank "${record[$key]:-}"; then
      printf '[validation] Record is missing required field: %s\n' "$key" >&2
      return 1
    fi
  done

  if [[ "${record[schema_version]}" != '1' ]]; then
    printf '[validation] Record has unsupported schema version: %s\n' "${record[schema_version]}" >&2
    return 1
  fi

  if [[ "${record[content_tree]}" != "$expected_tree_hash" ]]; then
    printf '[validation] Record content tree does not match the publish tree.\n' >&2
    printf '[validation] Expected: %s\n' "$expected_tree_hash" >&2
    printf '[validation] Recorded: %s\n' "${record[content_tree]}" >&2
    return 1
  fi

  if [[ ! "${record[recorded_at]}" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}[+-][0-9]{4}$ ]]; then
    printf '[validation] Record has an invalid recorded_at timestamp: %s\n' "${record[recorded_at]}" >&2
    return 1
  fi

  for check_name in user_facing_path fresh_install official_update web_ui verify_scripts; do
    case "${record[${check_name}_status]}" in
      performed|not_applicable)
        ;;
      *)
        printf '[validation] Record has invalid %s status: %s\n' "$check_name" "${record[${check_name}_status]}" >&2
        return 1
        ;;
    esac
  done

  return 0
}

real_device_validation_require_current_tree() {
  local tree_hash record_path

  tree_hash="$(real_device_validation_tree_hash)" || {
    printf '[validation] Cannot determine the current publish tree.\n' >&2
    return 1
  }
  record_path="$(real_device_validation_record_path "$tree_hash")" || return 1

  if [[ ! -f "$record_path" ]]; then
    printf '[validation] Missing real-device validation record for content tree: %s\n' "$tree_hash" >&2
    printf '[validation] Record the exact public-clean tree after validation with: bash scripts/record-real-device-validation.sh --help\n' >&2
    return 1
  fi

  real_device_validation_validate_record "$record_path" "$tree_hash" || return 1
  printf '[validation] Accepted real-device validation record for content tree: %s\n' "$tree_hash"
}
