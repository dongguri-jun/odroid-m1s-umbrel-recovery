#!/usr/bin/env bash
set -Eeuo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

DRY_RUN=0

# shellcheck source=scripts/m1s-backup-retention.sh
source scripts/m1s-backup-retention.sh

fail() {
  printf '[backup][FAIL] %s\n' "$1" >&2
  exit 1
}

pass() {
  printf '[backup][PASS] %s\n' "$1"
}

assert_eq() {
  local expected="$1"
  local actual="$2"
  local label="$3"
  [[ "$actual" == "$expected" ]] || fail "$label: expected '$expected', got '$actual'"
}

assert_contains() {
  local haystack="$1"
  local needle="$2"
  local label="$3"
  [[ "$haystack" == *"$needle"* ]] || fail "$label: missing '$needle'"
}

assert_exists() {
  local path="$1"
  local label="$2"
  [[ -e "$path" || -L "$path" ]] || fail "$label: missing '$path'"
}

assert_not_exists() {
  local path="$1"
  local label="$2"
  [[ ! -e "$path" && ! -L "$path" ]] || fail "$label: unexpectedly found '$path'"
}

run_cmd() {
  if [[ "$DRY_RUN" -eq 1 ]]; then
    printf '[DRY-RUN]'
    for arg in "$@"; do
      printf ' %q' "$arg"
    done
    printf '\n'
    return 0
  fi
  "$@"
}

TEST_TMPDIR="$(mktemp -d "${TMPDIR:-/tmp}/m1s-backup-retention.XXXXXX")"
trap 'rm -rf "$TEST_TMPDIR"' EXIT
FAKE_TIMESTAMP_FILE="$TEST_TMPDIR/fake-timestamp"

date() {
  local timestamp_format="${1:-}"
  case "$timestamp_format" in
    '+%s'|'+%Y%m%d%H%M%S') ;;
    *) fail "unexpected timestamp format: $timestamp_format" ;;
  esac
  printf '%s\n' "$(<"$FAKE_TIMESTAMP_FILE")"
}

backup_at() {
  local source_file="$1"
  local family_suffix="$2"
  local timestamp_format="$3"
  local timestamp="$4"
  printf '%s\n' "$timestamp" > "$FAKE_TIMESTAMP_FILE"
  m1s_backup_file_with_retention "$source_file" "$family_suffix" "$timestamp_format"
}

family_count() {
  local source_file="$1"
  local family_suffix="$2"
  local family_prefix="${source_file}${family_suffix}."
  local candidate timestamp
  local count=0
  for candidate in "$family_prefix"*; do
    [[ -e "$candidate" || -L "$candidate" ]] || continue
    timestamp="${candidate#"$family_prefix"}"
    [[ "$timestamp" =~ ^[0-9]+$ ]] || continue
    count=$((count + 1))
  done
  printf '%s\n' "$count"
}

assert_eq 5 "$M1S_BACKUP_RETENTION_COUNT" 'default retention count'

newest_source="$TEST_TMPDIR/newest/config"
mkdir -p "$(dirname "$newest_source")"
for timestamp in 8 9 10 11 12 13; do
  printf 'live-%s\n' "$timestamp" > "$newest_source"
  backup_at "$newest_source" '.bak' '+%s' "$timestamp" >/dev/null
done
printf 'live-14\n' > "$newest_source"
newest_output="$(backup_at "$newest_source" '.bak' '+%s' 14)"
assert_eq 5 "$(family_count "$newest_source" '.bak')" 'bounded family count'
assert_not_exists "$newest_source.bak.8" 'oldest backup pruning'
assert_not_exists "$newest_source.bak.9" 'second-oldest backup pruning'
for timestamp in 10 11 12 13 14; do
  assert_exists "$newest_source.bak.$timestamp" 'newest backup retention'
done
assert_contains "$newest_output" "Backup created: $newest_source.bak.14" 'created backup path report'
pass 'more than the retention limit keeps the newest five by embedded numeric timestamp'

family_source="$TEST_TMPDIR/families/fstab"
mkdir -p "$(dirname "$family_source")"
printf 'fstab-live\n' > "$family_source"
for timestamp in 101 102 103 104 105 106 107; do
  backup_at "$family_source" '.bak' '+%s' "$timestamp" >/dev/null
done
for timestamp in 20260101000001 20260101000002 20260101000003 20260101000004 20260101000005 20260101000006 20260101000007; do
  backup_at "$family_source" '.bak.data-alias' '+%Y%m%d%H%M%S' "$timestamp" >/dev/null
done
for timestamp in 20260201000001 20260201000002 20260201000003 20260201000004 20260201000005 20260201000006 20260201000007; do
  backup_at "$family_source" '.bak.update-repair' '+%Y%m%d%H%M%S' "$timestamp" >/dev/null
done
assert_eq 5 "$(family_count "$family_source" '.bak')" 'epoch family count'
assert_eq 5 "$(family_count "$family_source" '.bak.data-alias')" 'data-alias family count'
assert_eq 5 "$(family_count "$family_source" '.bak.update-repair')" 'update-repair family count'
assert_not_exists "$family_source.bak.101" 'epoch family oldest pruning'
assert_not_exists "$family_source.bak.data-alias.20260101000001" 'data-alias oldest pruning'
assert_not_exists "$family_source.bak.update-repair.20260201000001" 'update-repair oldest pruning'
assert_exists "$family_source.bak.107" 'epoch family newest retention'
assert_exists "$family_source.bak.data-alias.20260101000007" 'data-alias newest retention'
assert_exists "$family_source.bak.update-repair.20260201000007" 'update-repair newest retention'
pass 'epoch, data-alias, and update-repair families are pruned independently'

small_source="$TEST_TMPDIR/small/daemon.json"
mkdir -p "$(dirname "$small_source")"
printf 'daemon-live\n' > "$small_source"
for timestamp in 201 202 203; do
  backup_at "$small_source" '.bak' '+%s' "$timestamp" >/dev/null
done
assert_eq 3 "$(family_count "$small_source" '.bak')" 'under-limit family count'
for timestamp in 201 202 203; do
  assert_exists "$small_source.bak.$timestamp" 'under-limit backup retention'
done
pass 'fewer than five backups are left untouched'

protected_source="$TEST_TMPDIR/protected/avahi.conf"
mkdir -p "$(dirname "$protected_source")"
printf 'live-before\n' > "$protected_source"
printf 'keep-note\n' > "$protected_source.bak.note"
printf 'keep-extra\n' > "$protected_source.bak.0001.extra"
printf 'keep-other-family\n' > "$protected_source.bak.data-alias.note"
printf 'keep-neighbor\n' > "$TEST_TMPDIR/protected/neighbor.bak.1"
for timestamp in 301 302 303 304 305 306 307; do
  printf 'live-%s\n' "$timestamp" > "$protected_source"
  backup_at "$protected_source" '.bak' '+%s' "$timestamp" >/dev/null
done
assert_eq 'live-307' "$(<"$protected_source")" 'live file content after pruning'
pass 'the live file is never deleted or replaced by pruning'
assert_exists "$protected_source.bak.note" 'non-timestamp family neighbor'
assert_exists "$protected_source.bak.0001.extra" 'timestamp-prefix neighbor'
assert_exists "$protected_source.bak.data-alias.note" 'other-family neighbor'
assert_exists "$TEST_TMPDIR/protected/neighbor.bak.1" 'other live-path neighbor'
pass 'unrelated files sharing the directory are never deleted'

dry_root="$TEST_TMPDIR/dry-run"
dry_snapshot="$TEST_TMPDIR/dry-run-before"
dry_source="$dry_root/config.ini"
mkdir -p "$dry_root"
printf 'dry-live\n' > "$dry_source"
for timestamp in 401 402 403 404 405 406 407; do
  printf 'dry-backup-%s\n' "$timestamp" > "$dry_source.bak.$timestamp"
done
printf 'dry-unrelated\n' > "$dry_root/unrelated"
cp -a "$dry_root" "$dry_snapshot"
printf '408\n' > "$FAKE_TIMESTAMP_FILE"
DRY_RUN=1
dry_output="$(m1s_backup_file_with_retention "$dry_source" '.bak' '+%s')"
DRY_RUN=0
if ! diff -r "$dry_snapshot" "$dry_root" >/dev/null; then
  fail 'dry-run changed the fixture tree'
fi
assert_contains "$dry_output" "backup path: $dry_source.bak.408" 'dry-run backup path report'
assert_eq 7 "$(family_count "$dry_source" '.bak')" 'dry-run backup count'
pass 'DRY_RUN reports copy and pruning plans without mutating any file'

printf '[backup] retention tests complete\n'
