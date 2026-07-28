#!/usr/bin/env bash
set -Eeuo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

# shellcheck source=scripts/m1s-update-umbrel.sh
source scripts/m1s-update-umbrel.sh

matrix_fail() {
  printf '[matrix][FAIL] %s\n' "$1" >&2
  exit 1
}

matrix_assert_eq() {
  local expected="$1"
  local actual="$2"
  local label="$3"
  [[ "$actual" == "$expected" ]] || matrix_fail "$label: expected '$expected', got '$actual'"
}

matrix_assert_contains() {
  local needle="$1"
  local haystack="$2"
  local label="$3"
  [[ "$haystack" == *"$needle"* ]] || matrix_fail "$label: missing '$needle'"
}

matrix_new_test_state() {
  TEST_TMPDIR="$(mktemp -d "${TMPDIR:-/tmp}/updater-compatibility-matrix.XXXXXX")"
  INSTALL_STATE_DIR="$TEST_TMPDIR/etc/umbrel-recovery"
  INSTALL_STATE_FILE="$INSTALL_STATE_DIR/installed.json"
  DATA_DIR="$TEST_TMPDIR/mnt/fullnode"
  HOST_DATA_ALIAS="$TEST_TMPDIR/data"
  FSTAB_FILE="$TEST_TMPDIR/etc/fstab"
  SAFE_SHUTDOWN_SERVICE="$TEST_TMPDIR/etc/systemd/system/m1s-umbrel-autostart.service"
  FAKE_SYSTEMD_DIR="$TEST_TMPDIR/fake-systemd"
  FAKE_DOCKER_LOG="$TEST_TMPDIR/fake-docker.log"
  FAKE_ACTION_LOG="$TEST_TMPDIR/fake-actions.log"
  MATRIX_DOCKER_CONTAINER_PRESENT=1
  MATRIX_DATA_MOUNTED=1
  MATRIX_DATA_ALIAS_MOUNTED=0
  MATRIX_UMBREL_IMAGE_ID="sha256:matrix-image-id"
  AUTO_SYNC=0
  CHECK_ONLY=0
  DRY_RUN=0
  mkdir -p "$INSTALL_STATE_DIR" "$DATA_DIR" "$HOST_DATA_ALIAS" "$(dirname "$FSTAB_FILE")" "$FAKE_SYSTEMD_DIR"
  : > "$FSTAB_FILE"
  : > "$FAKE_DOCKER_LOG"
  : > "$FAKE_ACTION_LOG"
}

matrix_cleanup_test_state() {
  if [[ -n "${TEST_TMPDIR:-}" && -d "$TEST_TMPDIR" ]]; then
    rm -rf "$TEST_TMPDIR"
  fi
  unset TEST_TMPDIR INSTALL_STATE_DIR INSTALL_STATE_FILE DATA_DIR HOST_DATA_ALIAS FSTAB_FILE
  unset SAFE_SHUTDOWN_SERVICE FAKE_SYSTEMD_DIR FAKE_DOCKER_LOG FAKE_ACTION_LOG
  unset MATRIX_DOCKER_CONTAINER_PRESENT MATRIX_DATA_MOUNTED MATRIX_DATA_ALIAS_MOUNTED MATRIX_UMBREL_IMAGE_ID
}

trap matrix_cleanup_test_state EXIT

m1s_report_host_support() { :; }
require_root() { :; }
sync_repository_to_origin_main() { :; }

docker() {
  local rendered="$*"
  if [[ "$rendered" == "inspect umbrel" ]]; then
    printf 'docker inspect-container\n' >> "$FAKE_DOCKER_LOG"
    [[ "$MATRIX_DOCKER_CONTAINER_PRESENT" -eq 1 ]]
    return
  fi
  if [[ "$rendered" == *'.Destination "/data"'* ]]; then
    printf 'docker inspect-data-mount\n' >> "$FAKE_DOCKER_LOG"
    [[ "$MATRIX_DOCKER_CONTAINER_PRESENT" -eq 1 ]] || return 1
    printf '%s\n' "$DATA_DIR"
    return 0
  fi
  if [[ "$rendered" == *'.Destination "/var/run/docker.sock"'* ]]; then
    printf 'docker inspect-socket-mount\n' >> "$FAKE_DOCKER_LOG"
    [[ "$MATRIX_DOCKER_CONTAINER_PRESENT" -eq 1 ]] || return 1
    printf '/var/run/docker.sock\n'
    return 0
  fi
  if [[ "$rendered" == *'{{.Config.Image}}'* ]]; then
    printf 'docker inspect-image-ref\n' >> "$FAKE_DOCKER_LOG"
    [[ "$MATRIX_DOCKER_CONTAINER_PRESENT" -eq 1 ]] || return 1
    printf '%s\n' "$UMBREL_IMAGE"
    return 0
  fi
  if [[ "$rendered" == *'{{.Image}}'* ]]; then
    printf 'docker inspect-image-id\n' >> "$FAKE_DOCKER_LOG"
    [[ "$MATRIX_DOCKER_CONTAINER_PRESENT" -eq 1 ]] || return 1
    printf '%s\n' "$MATRIX_UMBREL_IMAGE_ID"
    return 0
  fi
  printf 'docker unexpected %s\n' "$rendered" >> "$FAKE_DOCKER_LOG"
  return 1
}

systemctl() {
  printf 'systemctl %s\n' "$*" >> "$FAKE_ACTION_LOG"
  return 0
}

findmnt() {
  local rendered="$*"
  if [[ "$rendered" == *"--target $DATA_DIR"* ]]; then
    if [[ "$rendered" == *"--output SOURCE"* ]]; then
      printf 'findmnt data-source\n' >> "$FAKE_ACTION_LOG"
      [[ "$MATRIX_DATA_MOUNTED" -eq 1 ]] || return 1
      printf '/dev/nvme0n1p1\n'
      return 0
    fi
    printf 'findmnt data-target\n' >> "$FAKE_ACTION_LOG"
    [[ "$MATRIX_DATA_MOUNTED" -eq 1 ]]
    return
  fi
  if [[ "$rendered" == *"--target $HOST_DATA_ALIAS"* ]]; then
    printf 'findmnt alias-target\n' >> "$FAKE_ACTION_LOG"
    [[ "$MATRIX_DATA_ALIAS_MOUNTED" -eq 1 ]]
    return
  fi
  printf 'findmnt unexpected %s\n' "$rendered" >> "$FAKE_ACTION_LOG"
  return 1
}

EXPECTED_MIGRATIONS=(
  "0.1.0_to_0.2.0"
  "0.2.0_to_0.3.0"
  "0.3.0_to_0.4.0"
  "0.4.0_to_0.4.1"
  "0.4.1_to_0.4.2"
  "0.4.2_to_0.4.3"
  "0.4.3_to_0.4.4"
  "0.4.4_to_0.4.5"
  "0.4.5_to_0.4.6"
  "0.4.6_to_0.4.7"
  "0.4.7_to_0.4.8"
  "0.4.8_to_0.4.9"
  "0.4.9_to_0.4.10"
  "0.4.10_to_0.4.11"
  "0.4.11_to_0.4.12"
  "0.4.12_to_0.4.13"
  "0.4.13_to_0.4.14"
  "0.4.14_to_0.4.15"
  "0.4.15_to_0.4.16"
  "0.4.16_to_0.4.17"
  "0.4.17_to_0.4.18"
  "0.4.18_to_0.5.0"
  "0.5.0_to_0.5.1"
  "0.5.1_to_0.5.2"
  "0.5.2_to_0.5.3"
  "0.5.3_to_0.5.4"
  "0.5.4_to_0.5.5"
  "0.5.5_to_0.5.6"
  "0.5.6_to_0.5.7"
  "0.5.7_to_0.5.8"
  "0.5.8_to_0.5.9"
  "0.5.9_to_0.5.10"
  "0.5.10_to_0.5.11"
  "0.5.11_to_0.5.12"
  "0.5.12_to_0.5.13"
  "0.5.13_to_0.5.14"
  "0.5.14_to_0.5.15"
  "0.5.15_to_0.5.16"
  "0.5.16_to_0.5.17"
  "0.5.17_to_0.5.18"
  "0.5.18_to_0.5.19"
  "0.5.19_to_0.5.20"
  "0.5.20_to_0.5.21"
  "0.5.21_to_0.5.22"
  "0.5.22_to_0.5.23"
  "0.5.23_to_0.5.24"
  "0.5.24_to_0.5.25"
  "0.5.25_to_0.5.26"
  "0.5.26_to_0.5.27"
  "0.5.27_to_0.5.28"
  "0.5.28_to_0.5.29"
  "0.5.29_to_0.5.30"
)

matrix_expected_plan_from() {
  local start_version="$1"
  local step
  local started=0
  local -a steps=()
  for step in "${EXPECTED_MIGRATIONS[@]}"; do
    if [[ "${step%%_to_*}" == "$start_version" ]]; then
      started=1
    fi
    if [[ "$started" -eq 1 ]]; then
      steps+=("$step")
    fi
  done
  [[ "${#steps[@]}" -gt 0 ]] || matrix_fail "fixture $start_version has no expected migration sequence"
  local IFS=' '
  printf '%s' "${steps[*]}"
}

matrix_plan_first() {
  local -a steps=()
  read -r -a steps <<< "$1"
  printf '%s' "${steps[0]}"
}

matrix_plan_last() {
  local -a steps=()
  read -r -a steps <<< "$1"
  printf '%s' "${steps[$((${#steps[@]} - 1))]}"
}

PLAN_0_1_0="$(matrix_expected_plan_from "0.1.0")"
PLAN_0_2_0="$(matrix_expected_plan_from "0.2.0")"
PLAN_0_5_15="$(matrix_expected_plan_from "0.5.15")"
PLAN_0_5_17="$(matrix_expected_plan_from "0.5.17")"
PLAN_0_5_24="$(matrix_expected_plan_from "0.5.24")"
PLAN_0_5_26="$(matrix_expected_plan_from "0.5.26")"

FIXTURE_ROWS=(
  "0.1.0|heuristic:docker-inspect|umbrel=running;data=mounted;docker_socket=/var/run/docker.sock|0.1.0_to_0.2.0|0.5.29_to_0.5.30|$PLAN_0_1_0|missing-umbrel-container-refuses-before-migration"
  "0.2.0|heuristic:mount-guard|umbrel=running;data=mounted;docker_socket=/var/run/docker.sock|0.2.0_to_0.3.0|0.5.29_to_0.5.30|$PLAN_0_2_0|missing-data-identity-refuses-before-migration"
  "0.5.15|installed.json:applied-steps-inference|umbrel=running;data=mounted;docker_socket=/var/run/docker.sock|0.5.15_to_0.5.16|0.5.29_to_0.5.30|$PLAN_0_5_15|malformed-install-state-refuses-before-migration"
  "0.5.17|installed.json:host_version|umbrel=running;data=mounted;data_alias=canonical;docker_socket=/var/run/docker.sock|0.5.17_to_0.5.18|0.5.29_to_0.5.30|$PLAN_0_5_17|unsafe-data-alias-refuses-before-migration"
  "0.5.24|installed.json:version|umbrel=running;data=mounted;system_containers=ready;docker_socket=/var/run/docker.sock|0.5.24_to_0.5.25|0.5.29_to_0.5.30|$PLAN_0_5_24|candidate-postcheck-failure-refuses-final-publication"
  "0.5.26|installed.json:host_version|umbrel=running;data=mounted;safe_shutdown=canonical;docker_socket=/var/run/docker.sock|0.5.26_to_0.5.27|0.5.29_to_0.5.30|$PLAN_0_5_26|safe-shutdown-install-failure-refuses-step-completion"
)

matrix_write_fixture_state() {
  local fixture_name="$1"
  local state_source="$2"
  case "$state_source" in
    heuristic:*) ;;
    installed.json:applied-steps-inference)
      printf '{"applied_steps":["0.5.14_to_0.5.15"]}\n' > "$INSTALL_STATE_FILE"
      ;;
    installed.json:host_version)
      printf '{"host_version":"%s","applied_steps":[]}\n' "$fixture_name" > "$INSTALL_STATE_FILE"
      ;;
    installed.json:version)
      printf '{"version":"%s","applied_steps":[]}\n' "$fixture_name" > "$INSTALL_STATE_FILE"
      ;;
    *) matrix_fail "fixture $fixture_name has unsupported state source '$state_source'" ;;
  esac
}

matrix_assert_fake_paths() {
  local fixture_name="$1"
  local path
  for path in "$INSTALL_STATE_DIR" "$INSTALL_STATE_FILE" "$DATA_DIR" "$HOST_DATA_ALIAS" "$FSTAB_FILE" "$FAKE_DOCKER_LOG" "$FAKE_ACTION_LOG"; do
    [[ "$path" == "$TEST_TMPDIR"/* ]] || matrix_fail "fixture $fixture_name escaped its temporary root: $path"
  done
  [[ ! -s "$FAKE_DOCKER_LOG" ]] || matrix_fail "fixture $fixture_name unexpectedly used fake Docker during contract setup"
  [[ ! -s "$FAKE_ACTION_LOG" ]] || matrix_fail "fixture $fixture_name unexpectedly used a fake host action during contract setup"
}

matrix_build_negative_mutant() {
  local failure_control="$1"
  local mutant_root="$TEST_TMPDIR/mutants/$failure_control"
  local mutant_updater="$mutant_root/scripts/m1s-update-umbrel.sh"
  mkdir -p "$mutant_root/scripts"
  cp scripts/m1s-support-policy.sh "$mutant_root/scripts/m1s-support-policy.sh"
  cp scripts/m1s-docker-lifecycle.sh "$mutant_root/scripts/m1s-docker-lifecycle.sh"
  cp scripts/m1s-backup-retention.sh "$mutant_root/scripts/m1s-backup-retention.sh"
  cp scripts/m1s-avahi-mdns.sh "$mutant_root/scripts/m1s-avahi-mdns.sh"
  python3 - scripts/m1s-update-umbrel.sh "$mutant_updater" "$failure_control" <<'PY'
from pathlib import Path
import sys

source_path, destination_path, failure_control = sys.argv[1:4]
text = Path(source_path).read_text(encoding="utf-8")
replacements = {
    "missing-umbrel-container-refuses-before-migration": (
        '''  docker inspect umbrel >/dev/null 2>&1 || {
    err "[0.4.5] Existing umbrel container not found; refusing to create a new one here."
    return 1
  }''',
        '''  docker inspect umbrel >/dev/null 2>&1 || {
    err "[0.4.5] Existing umbrel container not found; refusing to create a new one here."
    return 0
  }''',
    ),
    "missing-data-identity-refuses-before-migration": (
        '''  if ! findmnt --target "$DATA_DIR" >/dev/null 2>&1; then
    err "[0.4.5] $DATA_DIR is not mounted; refusing to touch the Umbrel container."
    err "[0.4.5] This prevents accidentally starting Umbrel with empty data on the root disk."
    return 1
  fi''',
        '''  if ! findmnt --target "$DATA_DIR" >/dev/null 2>&1; then
    err "[0.4.5] $DATA_DIR is not mounted; refusing to touch the Umbrel container."
    err "[0.4.5] This prevents accidentally starting Umbrel with empty data on the root disk."
    return 0
  fi''',
    ),
    "malformed-install-state-refuses-before-migration": (
        '''  [[ -f "$INSTALL_STATE_FILE" ]] || { err "$INSTALL_STATE_FILE is missing; refusing 1.7.3 in-place migration."; return 1; }
  python3 -m json.tool "$INSTALL_STATE_FILE" >/dev/null || { err "$INSTALL_STATE_FILE is not valid JSON."; return 1; }''',
        '''  [[ -f "$INSTALL_STATE_FILE" ]] || { err "$INSTALL_STATE_FILE is missing; refusing 1.7.3 in-place migration."; return 1; }
  python3 -m json.tool "$INSTALL_STATE_FILE" >/dev/null || { err "$INSTALL_STATE_FILE is not valid JSON."; return 0; }''',
    ),
    "unsafe-data-alias-refuses-before-migration": (
        '''  if [[ -L "$HOST_DATA_ALIAS" ]]; then
    err "$HOST_DATA_ALIAS is a symlink; refusing to use it for Umbrel data. A real bind mount is required."
    return 1
  fi''',
        '''  if [[ -L "$HOST_DATA_ALIAS" ]]; then
    err "$HOST_DATA_ALIAS is a symlink; refusing to use it for Umbrel data. A real bind mount is required."
    return 0
  fi''',
    ),
    "candidate-postcheck-failure-refuses-final-publication": (
        '''  fail_umbrel_transaction "candidate postcheck failed"
  return 1
}''',
        '''  fail_umbrel_transaction "candidate postcheck failed"
  return 0
}''',
    ),
    "safe-shutdown-install-failure-refuses-step-completion": (
        '''  verify_umbrel_shutdown_source || { err "Umbrel shutdown() safe-stop container patch could not be written"; return 1; }''',
        '''  verify_umbrel_shutdown_source || { err "Umbrel shutdown() safe-stop container patch could not be written"; return 0; }''',
    ),
}
try:
    original, mutant = replacements[failure_control]
except KeyError as error:
    raise SystemExit(f"unsupported failure-control mutant: {failure_control}") from error
if text.count(original) != 1:
    raise SystemExit(f"negative mutant construction failed: {failure_control}")
Path(destination_path).write_text(text.replace(original, mutant, 1), encoding="utf-8")
PY
  printf '%s\n' "$mutant_updater"
}

matrix_source_updater_under_test() {
  local updater_path="$1"
  local test_install_state_dir="$INSTALL_STATE_DIR"
  local test_install_state_file="$INSTALL_STATE_FILE"
  local test_data_dir="$DATA_DIR"
  local test_host_data_alias="$HOST_DATA_ALIAS"
  local test_fstab_file="$FSTAB_FILE"
  local test_safe_shutdown_service="$SAFE_SHUTDOWN_SERVICE"
  # shellcheck disable=SC1090 # The negative-mutant path is created under TEST_TMPDIR.
  source "$updater_path"
  INSTALL_STATE_DIR="$test_install_state_dir"
  INSTALL_STATE_FILE="$test_install_state_file"
  DATA_DIR="$test_data_dir"
  HOST_DATA_ALIAS="$test_host_data_alias"
  FSTAB_FILE="$test_fstab_file"
  SAFE_SHUTDOWN_SERVICE="$test_safe_shutdown_service"
  AUTO_SYNC=0
  CHECK_ONLY=0
  DRY_RUN=0
}

matrix_prepare_failure_control() {
  local failure_control="$1"
  case "$failure_control" in
    missing-umbrel-container-refuses-before-migration)
      MATRIX_DOCKER_CONTAINER_PRESENT=0
      # shellcheck disable=SC2317,SC2329 # Invoked indirectly through migration dispatch.
      apply_0_4_4_to_0_4_5() { printf 'matrix migration-apply\n' >> "$FAKE_ACTION_LOG"; }
      # shellcheck disable=SC2317,SC2329 # Invoked indirectly through migration dispatch.
      postcheck_0_4_4_to_0_4_5() { return 0; }
      ;;
    missing-data-identity-refuses-before-migration)
      MATRIX_DATA_MOUNTED=0
      # shellcheck disable=SC2317,SC2329 # Invoked indirectly through migration dispatch.
      apply_0_4_4_to_0_4_5() { printf 'matrix migration-apply\n' >> "$FAKE_ACTION_LOG"; }
      # shellcheck disable=SC2317,SC2329 # Invoked indirectly through migration dispatch.
      postcheck_0_4_4_to_0_4_5() { return 0; }
      ;;
    malformed-install-state-refuses-before-migration)
      printf '{malformed JSON\n' > "$INSTALL_STATE_FILE"
      # shellcheck disable=SC2317,SC2329 # Invoked indirectly through migration dispatch.
      apply_0_5_15_to_0_5_16() { printf 'matrix migration-apply\n' >> "$FAKE_ACTION_LOG"; }
      # shellcheck disable=SC2317,SC2329 # Invoked indirectly through migration dispatch.
      postcheck_0_5_15_to_0_5_16() { return 0; }
      ;;
    unsafe-data-alias-refuses-before-migration)
      rmdir "$HOST_DATA_ALIAS"
      ln -s "$DATA_DIR" "$HOST_DATA_ALIAS"
      # shellcheck disable=SC2317,SC2329 # Invoked indirectly through migration dispatch.
      apply_0_5_17_to_0_5_18() { printf 'matrix migration-apply\n' >> "$FAKE_ACTION_LOG"; }
      # shellcheck disable=SC2317,SC2329 # Invoked indirectly through migration dispatch.
      postcheck_0_5_17_to_0_5_18() { return 0; }
      ;;
    candidate-postcheck-failure-refuses-final-publication)
      # shellcheck disable=SC2317,SC2329 # Invoked indirectly through migration dispatch.
      apply_0_5_24_to_0_5_25() {
        printf 'matrix migration-apply\n' >> "$FAKE_ACTION_LOG"
        UMBREL_TRANSACTION_TARGET_IMAGE_ID="$MATRIX_UMBREL_IMAGE_ID"
        UMBREL_TRANSACTION_DATA_SOURCE="$DATA_DIR"
        UMBREL_TRANSACTION_ACTIVE=1
        UMBREL_TRANSACTION_MUTATED=0
      }
      # shellcheck disable=SC2317,SC2329 # Invoked by the candidate postcheck.
      candidate_umbrel_container_ready() {
        printf 'matrix candidate-readiness\n' >> "$FAKE_ACTION_LOG"
        return 1
      }
      ;;
    safe-shutdown-install-failure-refuses-step-completion)
      # shellcheck disable=SC2317,SC2329 # Invoked by the safe-shutdown installer.
      patch_umbrel_shutdown_source() { printf 'matrix patch-shutdown-source\n' >> "$FAKE_ACTION_LOG"; }
      # shellcheck disable=SC2317,SC2329 # Invoked by the safe-shutdown installer.
      verify_umbrel_shutdown_source() {
        printf 'matrix verify-shutdown-source\n' >> "$FAKE_ACTION_LOG"
        return 1
      }
      # shellcheck disable=SC2317,SC2329 # Invoked indirectly through migration dispatch.
      postcheck_umbrel_safe_shutdown() {
        printf 'matrix safe-shutdown-postcheck\n' >> "$FAKE_ACTION_LOG"
        return 0
      }
      ;;
    *)
      printf 'unsupported failure control: %s\n' "$failure_control" >&2
      return 1
      ;;
  esac
}

matrix_invoke_failure_control() {
  local failure_control="$1"
  local status
  case "$failure_control" in
    missing-umbrel-container-refuses-before-migration|missing-data-identity-refuses-before-migration)
      run_migration_step "0.4.4_to_0.4.5"
      ;;
    malformed-install-state-refuses-before-migration)
      run_migration_step "0.5.15_to_0.5.16"
      ;;
    unsafe-data-alias-refuses-before-migration)
      run_migration_step "0.5.17_to_0.5.18"
      ;;
    candidate-postcheck-failure-refuses-final-publication)
      run_migration_step "0.5.24_to_0.5.25"
      status=$?
      if [[ "$status" -eq 0 ]]; then
        printf 'matrix final-publication\n' >> "$FAKE_ACTION_LOG"
      fi
      return "$status"
      ;;
    safe-shutdown-install-failure-refuses-step-completion)
      run_migration_step "0.5.26_to_0.5.27"
      ;;
    *)
      return 1
      ;;
  esac
}

matrix_failure_message() {
  local failure_control="$1"
  case "$failure_control" in
    missing-umbrel-container-refuses-before-migration)
      printf '[0.4.5] Existing umbrel container not found; refusing to create a new one here.'
      ;;
    missing-data-identity-refuses-before-migration)
      printf '[0.4.5] %s is not mounted; refusing to touch the Umbrel container.' "$DATA_DIR"
      ;;
    malformed-install-state-refuses-before-migration)
      printf '%s is not valid JSON.' "$INSTALL_STATE_FILE"
      ;;
    unsafe-data-alias-refuses-before-migration)
      printf '%s is a symlink; refusing to use it for Umbrel data. A real bind mount is required.' "$HOST_DATA_ALIAS"
      ;;
    candidate-postcheck-failure-refuses-final-publication)
      printf 'Candidate postcheck diagnostic: predicate=top-level-readiness observed-state=not-ready'
      ;;
    safe-shutdown-install-failure-refuses-step-completion)
      printf 'Umbrel shutdown() safe-stop container patch could not be written'
      ;;
  esac
}

matrix_expected_docker_log() {
  local failure_control="$1"
  case "$failure_control" in
    missing-umbrel-container-refuses-before-migration|missing-data-identity-refuses-before-migration)
      printf '%s\n' \
        'docker inspect-container' \
        'docker inspect-image-ref' \
        'docker inspect-image-id'
      ;;
    malformed-install-state-refuses-before-migration)
      printf '%s\n' \
        'docker inspect-container' \
        'docker inspect-data-mount' \
        'docker inspect-socket-mount' \
        'docker inspect-image-ref' \
        'docker inspect-image-id'
      ;;
    unsafe-data-alias-refuses-before-migration)
      printf '%s\n' \
        'docker inspect-container' \
        'docker inspect-image-ref' \
        'docker inspect-image-id'
      ;;
    candidate-postcheck-failure-refuses-final-publication)
      printf '%s\n' \
        'docker inspect-container' \
        'docker inspect-data-mount' \
        'docker inspect-socket-mount' \
        'docker inspect-container' \
        'docker inspect-container' \
        'docker inspect-data-mount' \
        'docker inspect-socket-mount' \
        'docker inspect-image-ref' \
        'docker inspect-image-id'
      ;;
    safe-shutdown-install-failure-refuses-step-completion)
      printf '%s\n' \
        'docker inspect-container' \
        'docker inspect-container' \
        'docker inspect-image-ref' \
        'docker inspect-image-id'
      ;;
  esac
}

matrix_expected_action_log() {
  local failure_control="$1"
  case "$failure_control" in
    missing-umbrel-container-refuses-before-migration)
      return 0
      ;;
    missing-data-identity-refuses-before-migration)
      printf 'findmnt data-target\n'
      ;;
    malformed-install-state-refuses-before-migration)
      printf '%s\n' 'findmnt data-target' 'findmnt data-source'
      ;;
    unsafe-data-alias-refuses-before-migration)
      printf '%s\n' 'findmnt data-target' 'findmnt data-target'
      ;;
    candidate-postcheck-failure-refuses-final-publication)
      printf '%s\n' \
        'findmnt data-target' \
        'findmnt data-source' \
        'matrix migration-apply' \
        'findmnt data-target' \
        'findmnt data-source' \
        'matrix candidate-readiness'
      ;;
    safe-shutdown-install-failure-refuses-step-completion)
      printf '%s\n' \
        'findmnt data-target' \
        'matrix patch-shutdown-source' \
        'matrix verify-shutdown-source'
      ;;
  esac
}

matrix_state_value() {
  local key="$1"
  python3 - "$INSTALL_STATE_FILE" "$key" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as state_file:
    value = json.load(state_file).get(sys.argv[2])
if isinstance(value, list):
    print(" ".join(str(item) for item in value))
elif value is not None:
    print(value)
PY
}

matrix_assert_failure_timing() {
  local fixture_name="$1"
  local failure_control="$2"
  local expected_first="$3"
  local action_log
  action_log="$(<"$FAKE_ACTION_LOG")"
  case "$failure_control" in
    *-before-migration)
      [[ "$action_log" != *'matrix migration-apply'* ]] || {
        printf 'failure control reached migration apply\n' >&2
        return 1
      }
      ;;
    candidate-postcheck-failure-refuses-final-publication)
      [[ "$action_log" != *'matrix final-publication'* ]] || {
        printf 'failure control reached final publication\n' >&2
        return 1
      }
      matrix_assert_eq "$fixture_name" "$(matrix_state_value version)" "$fixture_name failed candidate postcheck preserves published version"
      ;;
    safe-shutdown-install-failure-refuses-step-completion)
      [[ "$action_log" != *'matrix safe-shutdown-postcheck'* ]] || {
        printf 'failure control reached safe-shutdown postcheck\n' >&2
        return 1
      }
      ;;
  esac
  [[ " $(matrix_state_value applied_steps) " != *" $expected_first "* ]] || {
    printf 'failure control recorded forbidden step completion\n' >&2
    return 1
  }
}

matrix_assert_runtime_logs() {
  local failure_control="$1"
  local expected_docker expected_actions actual_docker actual_actions
  expected_docker="$(matrix_expected_docker_log "$failure_control")"
  expected_actions="$(matrix_expected_action_log "$failure_control")"
  actual_docker="$(<"$FAKE_DOCKER_LOG")"
  actual_actions="$(<"$FAKE_ACTION_LOG")"
  [[ "$actual_docker" == "$expected_docker" ]] || {
    printf 'unexpected fake Docker log: expected <%s>, got <%s>\n' "$expected_docker" "$actual_docker" >&2
    return 1
  }
  [[ "$actual_actions" == "$expected_actions" ]] || {
    printf 'unexpected fake action log: expected <%s>, got <%s>\n' "$expected_actions" "$actual_actions" >&2
    return 1
  }
}

matrix_assert_failure_control() {
  local updater_path="$1"
  local fixture_name="$2"
  local failure_control="$3"
  local expected_first="$4"
  local output_file="$TEST_TMPDIR/failure-control.out"
  local expected_message output status path
  (
    matrix_source_updater_under_test "$updater_path"
    matrix_prepare_failure_control "$failure_control"
    set +e
    matrix_invoke_failure_control "$failure_control" > "$output_file" 2>&1
    status=$?
    set -e
    if [[ "$status" -eq 0 ]]; then
      printf 'expected non-zero refusal status\n' >&2
      return 1
    fi
    expected_message="$(matrix_failure_message "$failure_control")"
    output="$(<"$output_file")"
    [[ "$output" == *"$expected_message"* ]] || {
      printf 'missing expected refusal message: %s\n' "$expected_message" >&2
      return 1
    }
    matrix_assert_failure_timing "$fixture_name" "$failure_control" "$expected_first"
    matrix_assert_runtime_logs "$failure_control"
    for path in "$INSTALL_STATE_DIR" "$INSTALL_STATE_FILE" "$DATA_DIR" "$HOST_DATA_ALIAS" "$FSTAB_FILE" "$SAFE_SHUTDOWN_SERVICE" "$FAKE_DOCKER_LOG" "$FAKE_ACTION_LOG" "$output_file"; do
      [[ "$path" == "$TEST_TMPDIR"/* ]] || {
        printf 'failure control escaped its temporary root: %s\n' "$path" >&2
        return 1
      }
    done
  )
}

matrix_validate_fixture() {
  local row="$1"
  local fixture_name state_source runtime_facts expected_first expected_last expected_full failure_control
  local control_failure mutant_failure mutant_updater
  IFS='|' read -r fixture_name state_source runtime_facts expected_first expected_last expected_full failure_control <<< "$row"
  [[ -n "$fixture_name" && -n "$state_source" && -n "$runtime_facts" && -n "$expected_full" && -n "$failure_control" ]] \
    || matrix_fail "fixture row is incomplete: $row"
  matrix_assert_eq "$expected_first" "$(matrix_plan_first "$expected_full")" "$fixture_name expected first migration"
  matrix_assert_eq "$expected_last" "$(matrix_plan_last "$expected_full")" "$fixture_name expected last migration"
  matrix_assert_eq "0.5.29_to_0.5.30" "$expected_last" "$fixture_name targets the current final migration"
  matrix_assert_contains "umbrel=running" "$runtime_facts" "$fixture_name canonical runtime facts"
  matrix_assert_contains "docker_socket=/var/run/docker.sock" "$runtime_facts" "$fixture_name canonical runtime facts"

  matrix_cleanup_test_state
  matrix_new_test_state
  matrix_write_fixture_state "$fixture_name" "$state_source"
  matrix_assert_fake_paths "$fixture_name"

  if [[ "$state_source" == installed.json:* ]]; then
    python3 -m json.tool "$INSTALL_STATE_FILE" >/dev/null || matrix_fail "fixture $fixture_name did not create valid fake install state"
  else
    [[ ! -e "$INSTALL_STATE_FILE" ]] || matrix_fail "fixture $fixture_name heuristic state must not create installed.json"
  fi

  if ! control_failure="$(matrix_assert_failure_control "scripts/m1s-update-umbrel.sh" "$fixture_name" "$failure_control" "$expected_first" 2>&1)"; then
    matrix_fail "fixture $fixture_name failure control did not execute: $control_failure"
  fi

  matrix_cleanup_test_state
  matrix_new_test_state
  matrix_write_fixture_state "$fixture_name" "$state_source"
  matrix_assert_fake_paths "$fixture_name mutant"
  if ! mutant_updater="$(matrix_build_negative_mutant "$failure_control")"; then
    matrix_fail "negative mutant construction failed: $failure_control"
  fi
  if mutant_failure="$(matrix_assert_failure_control "$mutant_updater" "$fixture_name" "$failure_control" "$expected_first" 2>&1)"; then
    matrix_fail "negative mutant was accepted: $failure_control"
  fi
  if [[ "$mutant_failure" != "expected non-zero refusal status" ]]; then
    matrix_fail "negative mutant $failure_control rejected for unexpected reason: $mutant_failure"
  fi

  printf '[matrix][PASS] fixture=%s source=%s failure-control=%s\n' "$fixture_name" "$state_source" "$failure_control"
}

matrix_validate_all_fixtures() {
  local -A seen=()
  local -A seen_failure_controls=()
  local row fixture_name failure_control
  [[ "${#FIXTURE_ROWS[@]}" -eq 6 ]] || matrix_fail "expected exactly six fixture rows"
  for row in "${FIXTURE_ROWS[@]}"; do
    fixture_name="${row%%|*}"
    failure_control="${row##*|}"
    [[ -z "${seen[$fixture_name]:-}" ]] || matrix_fail "duplicate fixture row: $fixture_name"
    [[ -z "${seen_failure_controls[$failure_control]:-}" ]] || matrix_fail "duplicate failure control: $failure_control"
    seen["$fixture_name"]=1
    seen_failure_controls["$failure_control"]=1
    matrix_validate_fixture "$row"
  done
  for fixture_name in 0.1.0 0.2.0 0.5.15 0.5.17 0.5.24 0.5.26; do
    [[ "${seen[$fixture_name]:-}" == 1 ]] || matrix_fail "missing required fixture row: $fixture_name"
  done
}

matrix_validate_all_fixtures
printf '[matrix][PASS] six representative fixture contracts are isolated and explicit\n'
