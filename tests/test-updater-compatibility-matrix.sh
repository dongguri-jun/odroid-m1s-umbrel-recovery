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
}

trap matrix_cleanup_test_state EXIT

m1s_report_host_support() { :; }
require_root() { :; }
sync_repository_to_origin_main() { :; }

docker() {
  printf 'docker %s\n' "$*" >> "$FAKE_DOCKER_LOG"
  [[ "${1:-}" == "inspect" ]] && return 0
  return 0
}

systemctl() {
  printf 'systemctl %s\n' "$*" >> "$FAKE_ACTION_LOG"
  return 0
}

findmnt() {
  printf 'findmnt %s\n' "$*" >> "$FAKE_ACTION_LOG"
  return 0
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
  "0.1.0|heuristic:docker-inspect|umbrel=running;data=mounted;docker_socket=/var/run/docker.sock|0.1.0_to_0.2.0|0.5.27_to_0.5.28|$PLAN_0_1_0|missing-umbrel-container-refuses-before-migration"
  "0.2.0|heuristic:mount-guard|umbrel=running;data=mounted;docker_socket=/var/run/docker.sock|0.2.0_to_0.3.0|0.5.27_to_0.5.28|$PLAN_0_2_0|missing-data-identity-refuses-before-migration"
  "0.5.15|installed.json:applied-steps-inference|umbrel=running;data=mounted;docker_socket=/var/run/docker.sock|0.5.15_to_0.5.16|0.5.27_to_0.5.28|$PLAN_0_5_15|malformed-install-state-refuses-before-migration"
  "0.5.17|installed.json:host_version|umbrel=running;data=mounted;data_alias=canonical;docker_socket=/var/run/docker.sock|0.5.17_to_0.5.18|0.5.27_to_0.5.28|$PLAN_0_5_17|unsafe-data-alias-refuses-before-migration"
  "0.5.24|installed.json:version|umbrel=running;data=mounted;system_containers=ready;docker_socket=/var/run/docker.sock|0.5.24_to_0.5.25|0.5.27_to_0.5.28|$PLAN_0_5_24|candidate-postcheck-failure-refuses-final-publication"
  "0.5.26|installed.json:host_version|umbrel=running;data=mounted;safe_shutdown=canonical;docker_socket=/var/run/docker.sock|0.5.26_to_0.5.27|0.5.27_to_0.5.28|$PLAN_0_5_26|safe-shutdown-install-failure-refuses-step-completion"
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

matrix_validate_fixture() {
  local row="$1"
  local fixture_name state_source runtime_facts expected_first expected_last expected_full failure_control
  IFS='|' read -r fixture_name state_source runtime_facts expected_first expected_last expected_full failure_control <<< "$row"
  [[ -n "$fixture_name" && -n "$state_source" && -n "$runtime_facts" && -n "$expected_full" && -n "$failure_control" ]] \
    || matrix_fail "fixture row is incomplete: $row"
  matrix_assert_eq "$expected_first" "$(matrix_plan_first "$expected_full")" "$fixture_name expected first migration"
  matrix_assert_eq "$expected_last" "$(matrix_plan_last "$expected_full")" "$fixture_name expected last migration"
  matrix_assert_eq "0.5.27_to_0.5.28" "$expected_last" "$fixture_name targets the current final migration"
  matrix_assert_contains "umbrel=running" "$runtime_facts" "$fixture_name canonical runtime facts"
  matrix_assert_contains "docker_socket=/var/run/docker.sock" "$runtime_facts" "$fixture_name canonical runtime facts"
  matrix_assert_contains "refuses" "$failure_control" "$fixture_name failure control"

  matrix_cleanup_test_state
  matrix_new_test_state
  matrix_write_fixture_state "$fixture_name" "$state_source"
  matrix_assert_fake_paths "$fixture_name"

  if [[ "$state_source" == installed.json:* ]]; then
    python3 -m json.tool "$INSTALL_STATE_FILE" >/dev/null || matrix_fail "fixture $fixture_name did not create valid fake install state"
  else
    [[ ! -e "$INSTALL_STATE_FILE" ]] || matrix_fail "fixture $fixture_name heuristic state must not create installed.json"
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
