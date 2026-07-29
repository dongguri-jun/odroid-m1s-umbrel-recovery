#!/usr/bin/env bash
set -Eeuo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

# shellcheck source=scripts/real-device-validation.sh
source "$repo_root/scripts/real-device-validation.sh"

usage() {
  cat <<'USAGE'
Usage: bash scripts/record-real-device-validation.sh \
  --user-path 'performed: evidence' \
  --fresh-install 'performed|not_applicable: evidence' \
  --official-update 'performed|not_applicable: evidence' \
  --web-ui 'performed|not_applicable: evidence' \
  --verify-scripts 'performed: evidence' \
  --evidence-for 'measured facts' \
  --evidence-against 'contrary observations, or none observed' \
  --not-confirmed 'what was not established' \
  --honest-caveat 'limits of this validation'

Writes one local, append-only-by-content record for the current public-clean
tree. Every check must explicitly be performed or not_applicable, with
non-empty evidence. This command records evidence; it cannot independently
prove that device operations occurred.
USAGE
}

require_value() {
  local option="$1"
  local value="${2:-}"

  if [[ -z "$value" || "$value" == --* ]]; then
    printf 'Missing value for %s\n' "$option" >&2
    exit 2
  fi
}

declare -A options=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --user-path|--fresh-install|--official-update|--web-ui|--verify-scripts|--evidence-for|--evidence-against|--not-confirmed|--honest-caveat)
      require_value "$1" "${2:-}"
      key="${1#--}"
      key="${key//-/_}"
      if [[ -n "${options[$key]+present}" ]]; then
        printf 'Duplicate option: %s\n' "$1" >&2
        exit 2
      fi
      options[$key]="$2"
      shift 2
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
done

for key in user_path fresh_install official_update web_ui verify_scripts evidence_for evidence_against not_confirmed honest_caveat; do
  if [[ -z "${options[$key]+present}" ]]; then
    printf 'Missing required option: --%s\n' "${key//_/-}" >&2
    exit 2
  fi
  if real_device_validation_value_is_blank "${options[$key]}" || [[ "${options[$key]}" == *$'\n'* || "${options[$key]}" == *$'\r'* ]]; then
    printf 'Option --%s must contain one non-empty line.\n' "${key//_/-}" >&2
    exit 2
  fi
done

parse_check() {
  local option="$1"
  local supplied="$2"

  if [[ "$supplied" != *:* ]]; then
    printf '%s must use STATUS: evidence.\n' "$option" >&2
    exit 2
  fi

  check_status="${supplied%%:*}"
  check_evidence="${supplied#*:}"
  check_evidence="${check_evidence# }"
  case "$check_status" in
    performed|not_applicable)
      ;;
    *)
      printf '%s status must be performed or not_applicable.\n' "$option" >&2
      exit 2
      ;;
  esac
  if real_device_validation_value_is_blank "$check_evidence"; then
    printf '%s evidence must not be blank.\n' "$option" >&2
    exit 2
  fi
}

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    printf 'Missing required command: %s\n' "$1" >&2
    exit 1
  fi
}

require_cmd git
require_cmd date

current_branch="$(git branch --show-current)"
if [[ "$current_branch" != 'public-clean' ]]; then
  printf 'Real-device validation records must be created from public-clean. Current branch: %s\n' "$current_branch" >&2
  exit 1
fi

if [[ -n "$(git status --porcelain --untracked-files=all)" ]]; then
  printf 'Real-device validation records require a clean public-clean worktree. Commit the exact content first.\n' >&2
  exit 1
fi

tree_hash="$(real_device_validation_tree_hash)"
main_worktree="$(real_device_validation_main_worktree)"
record_dir="$main_worktree/.local/real-device-validations"
record_path="$record_dir/$tree_hash.record"

if [[ -e "$record_path" ]]; then
  printf 'A real-device validation record already exists for content tree: %s\n' "$tree_hash" >&2
  exit 1
fi

umask 077
mkdir -p "$record_dir"
temporary_record="$(mktemp "$record_dir/.${tree_hash}.XXXXXX")"
trap 'rm -f "$temporary_record"' EXIT

{
  printf '# Real-device validation record\n'
  printf '# This file records claims and evidence; it is not independent proof of device execution.\n'
  printf 'schema_version=1\n'
  printf 'content_tree=%s\n' "$tree_hash"
  printf 'recorded_at=%s\n' "$(TZ="Asia/Seoul" date '+%Y-%m-%dT%H:%M:%S%z')"
  for key in user_path fresh_install official_update web_ui verify_scripts; do
    parse_check "--${key//_/-}" "${options[$key]}"
    case "$key" in
      user_path)
        field_name='user_facing_path'
        ;;
      *)
        field_name="$key"
        ;;
    esac
    printf '%s_status=%s\n' "$field_name" "$check_status"
    printf '%s_evidence=%s\n' "$field_name" "$check_evidence"
  done
  printf '# EVIDENCE FOR\n'
  printf 'evidence_for=%s\n' "${options[evidence_for]}"
  printf '# EVIDENCE AGAINST\n'
  printf 'evidence_against=%s\n' "${options[evidence_against]}"
  printf '# NOT CONFIRMED\n'
  printf 'not_confirmed=%s\n' "${options[not_confirmed]}"
  printf '# HONEST CAVEAT\n'
  printf 'honest_caveat=%s\n' "${options[honest_caveat]}"
} > "$temporary_record"

chmod 600 "$temporary_record"
mv "$temporary_record" "$record_path"
trap - EXIT

printf 'Recorded real-device validation for content tree: %s\n' "$tree_hash"
