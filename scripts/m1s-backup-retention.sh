#!/usr/bin/env bash

M1S_BACKUP_RETENTION_COUNT="${M1S_BACKUP_RETENTION_COUNT:-5}"

m1s_backup_file_with_retention() {
  local source_file="$1"
  local family_suffix="$2"
  local timestamp_format="$3"
  local retention_count="$M1S_BACKUP_RETENTION_COUNT"
  local timestamp family_prefix backup_path candidate candidate_timestamp
  local newest_timestamp swap_path
  local candidate_value newest_value
  local index candidate_index newest_index
  local backup_path_seen=0
  local -a backups=()

  if [[ ! "$family_suffix" =~ ^\.[A-Za-z0-9][A-Za-z0-9._-]*$ ]]; then
    printf '[ERROR] Invalid backup family suffix: %s\n' "$family_suffix" >&2
    return 2
  fi
  if [[ ! "$retention_count" =~ ^[1-9][0-9]*$ ]]; then
    printf '[ERROR] Invalid backup retention count: %s\n' "$retention_count" >&2
    return 2
  fi

  timestamp="$(date "$timestamp_format")"
  if [[ ! "$timestamp" =~ ^[0-9]+$ ]]; then
    printf '[ERROR] Backup timestamp must contain only digits: %s\n' "$timestamp" >&2
    return 2
  fi

  family_prefix="${source_file}${family_suffix}."
  backup_path="${family_prefix}${timestamp}"
  run_cmd cp -- "$source_file" "$backup_path"

  if [[ "${DRY_RUN:-0}" -eq 1 ]]; then
    printf '[DRY-RUN] backup path: %s\n' "$backup_path"
  else
    printf '[INFO] Backup created: %s\n' "$backup_path"
  fi

  for candidate in "$family_prefix"*; do
    [[ -e "$candidate" || -L "$candidate" ]] || continue
    candidate_timestamp="${candidate#"$family_prefix"}"
    [[ "$candidate_timestamp" =~ ^[0-9]+$ ]] || continue
    backups+=("$candidate")
    if [[ "$candidate" == "$backup_path" ]]; then
      backup_path_seen=1
    fi
  done

  if [[ "${DRY_RUN:-0}" -eq 1 && "$backup_path_seen" -eq 0 ]]; then
    backups+=("$backup_path")
  fi

  for ((index = 0; index < ${#backups[@]}; index++)); do
    newest_index="$index"
    newest_timestamp="${backups[$index]#"$family_prefix"}"
    newest_value=$((10#$newest_timestamp))
    for ((candidate_index = index + 1; candidate_index < ${#backups[@]}; candidate_index++)); do
      candidate_timestamp="${backups[$candidate_index]#"$family_prefix"}"
      candidate_value=$((10#$candidate_timestamp))
      if ((candidate_value > newest_value)); then
        newest_index="$candidate_index"
        newest_value="$candidate_value"
      fi
    done
    if ((newest_index != index)); then
      swap_path="${backups[$index]}"
      backups[index]="${backups[$newest_index]}"
      backups[newest_index]="$swap_path"
    fi
  done

  for ((index = retention_count; index < ${#backups[@]}; index++)); do
    run_cmd rm -f -- "${backups[$index]}"
  done
}
