#!/usr/bin/env bash
set -Eeuo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

# shellcheck source=scripts/m1s-update-system-packages.sh
source scripts/m1s-update-system-packages.sh

m1s_host_os_id() { printf 'ubuntu'; }
m1s_host_os_version() { printf '22.04'; }
m1s_host_kernel_release() { printf '5.10.160-odroid-arm64'; }
m1s_host_architecture() { printf 'aarch64'; }
m1s_host_model() { printf 'Hardkernel ODROID-M1S'; }

fail() {
  printf '[unit][FAIL] %s\n' "$1" >&2
  exit 1
}

pass() {
  printf '[unit][PASS] %s\n' "$1"
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

assert_before() {
  local text="$1"
  local before="$2"
  local after="$3"
  local label="$4"
  local before_position after_position
  before_position="$(python3 -c 'import sys; print(sys.stdin.read().find(sys.argv[1]))' "$before" <<<"$text")"
  after_position="$(python3 -c 'import sys; print(sys.stdin.read().find(sys.argv[1]))' "$after" <<<"$text")"
  [[ "$before_position" -ge 0 && "$after_position" -ge 0 && "$before_position" -lt "$after_position" ]] || fail "$label"
}

printf '[unit] system package support policy ordering\n'
system_updater_script="$(<scripts/m1s-update-system-packages.sh)"
assert_contains "$system_updater_script" 'm1s-support-policy.sh' 'System package updater must source the shared support policy'
system_updater_main="${system_updater_script#*main() \{}"
assert_before "$system_updater_main" 'm1s_report_host_support' 'apt_update_command' 'System package updater must report unvalidated hosts before apt changes'
pass 'system package updater warning precedes apt mutation'

ORIGINAL_PATH="$PATH"
TEST_TMPDIR=""
cleanup() {
  if [[ -n "$TEST_TMPDIR" && -d "$TEST_TMPDIR" ]]; then
    rm -rf "$TEST_TMPDIR"
  fi
}
trap cleanup EXIT

new_tmpdir() {
  cleanup
  TEST_TMPDIR="$(mktemp -d)"
  mkdir -p "$TEST_TMPDIR/bin"
}

printf '[unit] system package updater docker stop failure recovery\n'
new_tmpdir
cat > "$TEST_TMPDIR/bin/docker" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$DOCKER_LOG"
case "$1" in
  stop)
    exit 42
    ;;
  start)
    exit 0
    ;;
  *)
    exit 0
    ;;
esac
EOF
chmod +x "$TEST_TMPDIR/bin/docker"
DOCKER_LOG="$TEST_TMPDIR/docker.log"
export DOCKER_LOG
PATH="$TEST_TMPDIR/bin:$ORIGINAL_PATH"
DRY_RUN=0
CONTAINERS_STOPPED=0
REBOOTING=0
STOPPED_CONTAINERS=(umbrel bitcoin)
if stop_running_containers; then
  fail 'docker stop failure should make stop_running_containers fail'
else
  status="$?"
fi
assert_eq "42" "$status" 'docker stop original exit code is preserved'
docker_log="$(cat "$DOCKER_LOG")"
assert_contains "$docker_log" 'stop --timeout 300 umbrel bitcoin' 'docker stop should target the captured containers'
assert_contains "$docker_log" 'start bitcoin' 'docker start should run after docker stop failure'
assert_contains "$docker_log" 'start umbrel' 'docker start should include every restartable captured container'
assert_eq "0" "$CONTAINERS_STOPPED" 'container restart clears stopped state after stop failure recovery'
pass 'docker stop failure restarts captured containers and preserves status'

printf '[unit] system package updater waits for Umbrel-managed container recreation\n'
new_tmpdir
cat > "$TEST_TMPDIR/bin/docker" <<'EOF'
#!/usr/bin/env bash
set -eu

log() {
  printf '%s\n' "$*" >> "$DOCKER_LOG"
}

managed_label='/opt/umbreld/source/modules/apps/legacy-compat'

case "$1" in
  ps)
    if [[ "$*" == *'{{.Names}} {{.Status}}'* ]]; then
      printf 'umbrel_auth Up test\numbrel_tor_proxy Up test\numbrel Up test\nindependent Up test\n'
    else
      printf 'umbrel_auth\numbrel_tor_proxy\numbrel\nindependent\n'
    fi
    ;;
  stop)
    log "$*"
    : > "$CONTAINERS_STOPPED_BY_DOCKER"
    ;;
  start)
    log "$*"
    if [[ "${2:-}" == 'umbrel' ]]; then
      : > "$PARENT_STARTED"
    fi
    ;;
  container)
    [[ "${2:-}" == 'inspect' ]] || exit 1
    container="${3:-}"
    if [[ "$container" == 'umbrel_auth' || "$container" == 'umbrel_tor_proxy' ]]; then
      if [[ -f "$PARENT_STARTED" ]]; then
        exit 1
      fi
    fi
    ;;
  inspect)
    container="${2:-}"
    if [[ "$*" == *'com.docker.compose.project.working_dir'* ]]; then
      [[ ! -f "$CONTAINERS_STOPPED_BY_DOCKER" ]] || exit 1
      if [[ "$container" == 'umbrel_auth' || "$container" == 'umbrel_tor_proxy' ]]; then
        printf '%s\n' "$managed_label"
      fi
      exit 0
    fi
    if [[ "$*" == *'{{.State.Status}}'* && ( "$container" == 'umbrel_auth' || "$container" == 'umbrel_tor_proxy' ) ]]; then
      [[ -f "$PARENT_STARTED" ]] || exit 1
      count_file="$TEST_TMPDIR/${container}.state-count"
      count=0
      [[ -f "$count_file" ]] && count="$(cat "$count_file")"
      count=$((count + 1))
      printf '%s\n' "$count" > "$count_file"
      [[ "$count" -gt 1 ]] || exit 1
      printf 'running\n'
      exit 0
    fi
    ;;
esac
EOF
cat > "$TEST_TMPDIR/bin/apt-get" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "$APT_LOG"
EOF
cat > "$TEST_TMPDIR/bin/dpkg" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "$DPKG_LOG"
EOF
chmod +x "$TEST_TMPDIR/bin/"*
DOCKER_LOG="$TEST_TMPDIR/docker.log"
APT_LOG="$TEST_TMPDIR/apt.log"
DPKG_LOG="$TEST_TMPDIR/dpkg.log"
PARENT_STARTED="$TEST_TMPDIR/parent-started"
CONTAINERS_STOPPED_BY_DOCKER="$TEST_TMPDIR/containers-stopped"
export DOCKER_LOG APT_LOG DPKG_LOG PARENT_STARTED CONTAINERS_STOPPED_BY_DOCKER TEST_TMPDIR
PATH="$TEST_TMPDIR/bin:$ORIGINAL_PATH"
managed_recovery_output="$TEST_TMPDIR/managed-recovery.out"
(
  require_root() { return 0; }
  reboot_required() { return 1; }
  DRY_RUN=0
  NO_REBOOT=0
  CONTAINERS_STOPPED=0
  REBOOTING=0
  STOPPED_CONTAINERS=()
  main --no-reboot
) >"$managed_recovery_output" 2>&1
managed_recovery_log="$(cat "$managed_recovery_output")"
docker_log="$(cat "$DOCKER_LOG")"
[[ "$managed_recovery_log" != *'no longer exists'* ]] || fail 'Umbrel-managed children must be awaited instead of being reported as missing'
assert_contains "$docker_log" 'start umbrel' 'managed recovery should start the top-level Umbrel container'
assert_contains "$docker_log" 'start independent' 'managed recovery should directly restart independent containers'
[[ "$docker_log" != *'start umbrel_auth'* ]] || fail 'Umbrel-managed auth child must not be restarted directly'
[[ "$docker_log" != *'start umbrel_tor_proxy'* ]] || fail 'Umbrel-managed Tor child must not be restarted directly'
pass 'Umbrel-managed children are verified after top-level Umbrel recovery'

printf '[unit] system package updater noninteractive repair commands\n'
DRY_RUN=1
repair_output="$(dpkg_configure_command; apt_fix_install_command)"
assert_contains "$repair_output" 'env DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a APT_LISTCHANGES_FRONTEND=none dpkg --force-confdef --force-confold --configure -a' 'dpkg configure should be noninteractive with config defaults'
assert_contains "$repair_output" 'env DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a APT_LISTCHANGES_FRONTEND=none apt-get -o DPkg::Lock::Timeout=300 -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold -f install -y' 'apt fix install should use noninteractive config defaults and wait for apt locks'
pass 'dpkg and apt repair paths use noninteractive config defaults and apt lock timeout'

printf '[unit] system package updater reboot-required --no-reboot path\n'
new_tmpdir
cat > "$TEST_TMPDIR/bin/docker" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  ps)
    if [[ "$*" == *'{{.Names}} {{.Status}}'* ]]; then
      printf 'bitcoin_app_1 Up test\numbrel Up test\n'
    else
      printf 'bitcoin_app_1\numbrel\n'
    fi
    ;;
  *)
    printf '%s\n' "$*" >> "$DOCKER_LOG"
    ;;
esac
EOF
cat > "$TEST_TMPDIR/bin/apt-get" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "$APT_LOG"
EOF
cat > "$TEST_TMPDIR/bin/dpkg" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "$DPKG_LOG"
EOF
cat > "$TEST_TMPDIR/bin/systemctl" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "$SYSTEMCTL_LOG"
EOF
chmod +x "$TEST_TMPDIR/bin/"*
DOCKER_LOG="$TEST_TMPDIR/docker.log"
APT_LOG="$TEST_TMPDIR/apt.log"
DPKG_LOG="$TEST_TMPDIR/dpkg.log"
SYSTEMCTL_LOG="$TEST_TMPDIR/systemctl.log"
export DOCKER_LOG APT_LOG DPKG_LOG SYSTEMCTL_LOG
PATH="$TEST_TMPDIR/bin:$ORIGINAL_PATH"
(
  require_root() { return 0; }
  reboot_required() { return 0; }
  DRY_RUN=0
  NO_REBOOT=0
  CONTAINERS_STOPPED=0
  REBOOTING=0
  STOPPED_CONTAINERS=()
  main --no-reboot
)
docker_log="$(cat "$DOCKER_LOG")"
assert_contains "$docker_log" 'stop --timeout 300 bitcoin_app_1 umbrel' '--no-reboot path should stop containers'
assert_contains "$docker_log" 'start umbrel' '--no-reboot path should restart Umbrel first'
assert_contains "$docker_log" 'start bitcoin_app_1' '--no-reboot path should restart app containers when still present'
[[ ! -s "$SYSTEMCTL_LOG" ]] || fail '--no-reboot path should not call systemctl reboot'
pass 'forced reboot-required --no-reboot restarts containers without reboot'

printf '[unit] system package updater reboot-required automatic reboot path\n'
new_tmpdir
cat > "$TEST_TMPDIR/bin/docker" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  ps)
    if [[ "$*" == *'{{.Names}} {{.Status}}'* ]]; then
      printf 'bitcoin_app_1 Up test\numbrel Up test\n'
    else
      printf 'bitcoin_app_1\numbrel\n'
    fi
    ;;
  *)
    printf '%s\n' "$*" >> "$DOCKER_LOG"
    ;;
esac
EOF
cat > "$TEST_TMPDIR/bin/apt-get" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$APT_LOG"
EOF
cat > "$TEST_TMPDIR/bin/dpkg" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$DPKG_LOG"
EOF
cat > "$TEST_TMPDIR/bin/systemctl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$SYSTEMCTL_LOG"
EOF
chmod +x "$TEST_TMPDIR/bin/"*
DOCKER_LOG="$TEST_TMPDIR/docker.log"
APT_LOG="$TEST_TMPDIR/apt.log"
DPKG_LOG="$TEST_TMPDIR/dpkg.log"
SYSTEMCTL_LOG="$TEST_TMPDIR/systemctl.log"
export DOCKER_LOG APT_LOG DPKG_LOG SYSTEMCTL_LOG
PATH="$TEST_TMPDIR/bin:$ORIGINAL_PATH"
(
  require_root() { return 0; }
  reboot_required() { return 0; }
  DRY_RUN=0
  NO_REBOOT=0
  CONTAINERS_STOPPED=0
  REBOOTING=0
  STOPPED_CONTAINERS=()
  main
)
docker_log="$(cat "$DOCKER_LOG")"
systemctl_log="$(cat "$SYSTEMCTL_LOG")"
assert_contains "$docker_log" 'stop --timeout 300 bitcoin_app_1 umbrel' 'automatic reboot path should stop containers'
assert_contains "$systemctl_log" 'reboot' 'automatic reboot path should call systemctl reboot'
[[ "$docker_log" != *'start bitcoin_app_1'* ]] || fail 'automatic reboot path should not restart containers before reboot'
[[ "$docker_log" != *'start umbrel'* ]] || fail 'automatic reboot path should not restart Umbrel before reboot'
pass 'forced reboot-required path calls reboot without restarting containers'

printf '[unit] system package updater apt upgrade failure recovery\n'
new_tmpdir
cat > "$TEST_TMPDIR/bin/docker" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  ps)
    if [[ "$*" == *'{{.Names}} {{.Status}}'* ]]; then
      printf 'bitcoin_app_1 Up test\numbrel Up test\n'
    else
      printf 'bitcoin_app_1\numbrel\n'
    fi
    ;;
  *)
    printf '%s\n' "$*" >> "$DOCKER_LOG"
    ;;
esac
EOF
cat > "$TEST_TMPDIR/bin/apt-get" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$APT_LOG"
for arg in "$@"; do
  if [[ "$arg" == 'upgrade' ]]; then
    exit 55
  fi
done
EOF
cat > "$TEST_TMPDIR/bin/dpkg" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$DPKG_LOG"
EOF
chmod +x "$TEST_TMPDIR/bin/"*
DOCKER_LOG="$TEST_TMPDIR/docker.log"
APT_LOG="$TEST_TMPDIR/apt.log"
DPKG_LOG="$TEST_TMPDIR/dpkg.log"
export DOCKER_LOG APT_LOG DPKG_LOG
PATH="$TEST_TMPDIR/bin:$ORIGINAL_PATH"
set +e
(
  require_root() { return 0; }
  reboot_required() { return 1; }
  DRY_RUN=0
  NO_REBOOT=0
  CONTAINERS_STOPPED=0
  REBOOTING=0
  STOPPED_CONTAINERS=()
  main
)
status="$?"
set -e
[[ "$status" -ne 0 ]] || fail 'apt upgrade failure should make main fail'
assert_eq "55" "$status" 'apt upgrade failure exit code should be preserved'
docker_log="$(cat "$DOCKER_LOG")"
assert_contains "$docker_log" 'stop --timeout 300 bitcoin_app_1 umbrel' 'apt failure path should stop containers before upgrade'
assert_contains "$docker_log" 'start umbrel' 'apt failure path should restart Umbrel'
assert_contains "$docker_log" 'start bitcoin_app_1' 'apt failure path should restart app containers when still present'
[[ "$(cat "$APT_LOG")" != *'clean'* ]] || fail 'apt upgrade failure should not run apt clean after failed package update'
pass 'apt upgrade failure restarts containers and preserves status without cleaning apt cache'

printf '[unit] system package updater CLI argument handling\n'
new_tmpdir
cli_out="$TEST_TMPDIR/m1s-cli-out"
cli_err="$TEST_TMPDIR/m1s-cli-err"
cli_help="$TEST_TMPDIR/m1s-cli-help"
set +e
bash scripts/m1s-update-system-packages.sh --bad-option >"$cli_out" 2>"$cli_err"
status="$?"
set -e
assert_eq "2" "$status" 'unknown option should exit 2'
assert_contains "$(cat "$cli_err")" 'Unknown argument: --bad-option' 'unknown option should print the rejected option'
assert_eq "$SCRIPT_VERSION" "$(bash scripts/m1s-update-system-packages.sh --version)" '--version should print script version'
bash scripts/m1s-update-system-packages.sh --help >"$cli_help"
assert_contains "$(cat "$cli_help")" 'Usage:' '--help should print usage'
pass 'CLI rejects unknown options and supports --version/--help'

printf '[unit] system package updater Docker absent and empty-container paths\n'
new_tmpdir
cat > "$TEST_TMPDIR/bin/apt-get" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "$APT_LOG"
EOF
cat > "$TEST_TMPDIR/bin/dpkg" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "$DPKG_LOG"
EOF
cat > "$TEST_TMPDIR/bin/systemctl" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "$SYSTEMCTL_LOG"
EOF
chmod +x "$TEST_TMPDIR/bin/"*
APT_LOG="$TEST_TMPDIR/apt.log"
DPKG_LOG="$TEST_TMPDIR/dpkg.log"
SYSTEMCTL_LOG="$TEST_TMPDIR/systemctl.log"
export APT_LOG DPKG_LOG SYSTEMCTL_LOG
(
  PATH="$TEST_TMPDIR/bin"
  export PATH
  if command -v docker >/dev/null 2>&1; then
    fail 'Docker-absent fixture resolved a real docker executable'
  fi
  require_root() { return 0; }
  reboot_required() { return 1; }
  DRY_RUN=0
  NO_REBOOT=0
  CONTAINERS_STOPPED=0
  REBOOTING=0
  STOPPED_CONTAINERS=()
  main
)
[[ ! -e "$TEST_TMPDIR/docker.log" ]] || fail 'Docker absent path should not call docker'
apt_log="$(cat "$APT_LOG")"
assert_contains "$apt_log" 'DPkg::Lock::Timeout=300 update' 'Docker absent path should still run apt update with apt lock timeout'
assert_contains "$apt_log" 'DPkg::Lock::Timeout=300 clean' 'Docker absent path should clean apt cache after successful checks'
pass 'Docker absent path updates packages and cleans apt cache without container operations'

new_tmpdir
cat > "$TEST_TMPDIR/bin/docker" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  ps) exit 0 ;;
  *) printf '%s\n' "$*" >> "$DOCKER_LOG" ;;
esac
EOF
cat > "$TEST_TMPDIR/bin/apt-get" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$APT_LOG"
EOF
cat > "$TEST_TMPDIR/bin/dpkg" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$DPKG_LOG"
EOF
chmod +x "$TEST_TMPDIR/bin/"*
DOCKER_LOG="$TEST_TMPDIR/docker.log"
APT_LOG="$TEST_TMPDIR/apt.log"
DPKG_LOG="$TEST_TMPDIR/dpkg.log"
export DOCKER_LOG APT_LOG DPKG_LOG
PATH="$TEST_TMPDIR/bin:$ORIGINAL_PATH"
(
  require_root() { return 0; }
  reboot_required() { return 1; }
  DRY_RUN=0
  NO_REBOOT=0
  CONTAINERS_STOPPED=0
  REBOOTING=0
  STOPPED_CONTAINERS=()
  main
)
[[ ! -s "$DOCKER_LOG" ]] || fail 'Empty container path should not stop or start containers'
pass 'Empty Docker container path avoids container mutation'

printf '[unit] system package updater apt update failure does not stop containers\n'
new_tmpdir
cat > "$TEST_TMPDIR/bin/docker" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$DOCKER_LOG"
case "$1" in
  ps) printf 'umbrel\n' ;;
esac
EOF
cat > "$TEST_TMPDIR/bin/apt-get" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$APT_LOG"
if [[ "$*" == *' update'* ]]; then exit 31; fi
EOF
chmod +x "$TEST_TMPDIR/bin/"*
DOCKER_LOG="$TEST_TMPDIR/docker.log"
APT_LOG="$TEST_TMPDIR/apt.log"
export DOCKER_LOG APT_LOG
PATH="$TEST_TMPDIR/bin:$ORIGINAL_PATH"
set +e
(
  require_root() { return 0; }
  reboot_required() { return 1; }
  DRY_RUN=0
  NO_REBOOT=0
  CONTAINERS_STOPPED=0
  REBOOTING=0
  STOPPED_CONTAINERS=()
  main
)
status="$?"
set -e
assert_eq "31" "$status" 'apt update failure exit code should be preserved'
[[ ! -s "$DOCKER_LOG" ]] || fail 'apt update failure should occur before any docker operation'
[[ "$(cat "$APT_LOG")" != *'clean'* ]] || fail 'apt update failure should not clean apt cache'
pass 'apt update failure fails before containers are touched or apt cache is cleaned'

printf '[unit] system package updater dpkg and apt-fix failure recovery\n'
for mode in dpkg aptfix; do
  new_tmpdir
  cat > "$TEST_TMPDIR/bin/docker" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  ps)
    if [[ "$*" == *'{{.Names}} {{.Status}}'* ]]; then printf 'umbrel Up test\n'; else printf 'umbrel\n'; fi
    ;;
  *) printf '%s\n' "$*" >> "$DOCKER_LOG" ;;
esac
EOF
  cat > "$TEST_TMPDIR/bin/apt-get" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$APT_LOG"
if [[ "${FAIL_MODE:-}" == aptfix && "$*" == *'-f install -y'* ]]; then exit 57; fi
EOF
  cat > "$TEST_TMPDIR/bin/dpkg" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$DPKG_LOG"
if [[ "${FAIL_MODE:-}" == dpkg ]]; then exit 56; fi
EOF
  chmod +x "$TEST_TMPDIR/bin/"*
  DOCKER_LOG="$TEST_TMPDIR/docker.log"
  APT_LOG="$TEST_TMPDIR/apt.log"
  DPKG_LOG="$TEST_TMPDIR/dpkg.log"
  export DOCKER_LOG APT_LOG DPKG_LOG FAIL_MODE="$mode"
  PATH="$TEST_TMPDIR/bin:$ORIGINAL_PATH"
  set +e
  (
    require_root() { return 0; }
    reboot_required() { return 1; }
    DRY_RUN=0
    NO_REBOOT=0
    CONTAINERS_STOPPED=0
    REBOOTING=0
    STOPPED_CONTAINERS=()
    main
  )
  status="$?"
  set -e
  if [[ "$mode" == dpkg ]]; then assert_eq "56" "$status" 'dpkg failure exit code should be preserved'; else assert_eq "57" "$status" 'apt-fix failure exit code should be preserved'; fi
  docker_log="$(cat "$DOCKER_LOG")"
  assert_contains "$docker_log" 'stop --timeout 300 umbrel' "$mode failure should stop containers before repair"
  assert_contains "$docker_log" 'start umbrel' "$mode failure should restart containers after error"
done
pass 'dpkg and apt-fix failures restart containers and preserve status'

printf '[unit] system package updater reboot command failure recovery\n'
new_tmpdir
cat > "$TEST_TMPDIR/bin/docker" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  ps)
    if [[ "$*" == *'{{.Names}} {{.Status}}'* ]]; then printf 'umbrel Up test\n'; else printf 'umbrel\n'; fi
    ;;
  *) printf '%s\n' "$*" >> "$DOCKER_LOG" ;;
esac
EOF
cat > "$TEST_TMPDIR/bin/apt-get" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$APT_LOG"
EOF
cat > "$TEST_TMPDIR/bin/dpkg" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$DPKG_LOG"
EOF
cat > "$TEST_TMPDIR/bin/systemctl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$SYSTEMCTL_LOG"
exit 58
EOF
chmod +x "$TEST_TMPDIR/bin/"*
DOCKER_LOG="$TEST_TMPDIR/docker.log"
APT_LOG="$TEST_TMPDIR/apt.log"
DPKG_LOG="$TEST_TMPDIR/dpkg.log"
SYSTEMCTL_LOG="$TEST_TMPDIR/systemctl.log"
export DOCKER_LOG APT_LOG DPKG_LOG SYSTEMCTL_LOG
PATH="$TEST_TMPDIR/bin:$ORIGINAL_PATH"
set +e
(
  require_root() { return 0; }
  reboot_required() { return 0; }
  DRY_RUN=0
  NO_REBOOT=0
  CONTAINERS_STOPPED=0
  REBOOTING=0
  STOPPED_CONTAINERS=()
  main
)
status="$?"
set -e
assert_eq "58" "$status" 'reboot command failure exit code should be preserved'
docker_log="$(cat "$DOCKER_LOG")"
assert_contains "$docker_log" 'stop --timeout 300 umbrel' 'reboot failure path should stop containers before reboot decision'
assert_contains "$docker_log" 'start umbrel' 'reboot failure path should restart containers'
pass 'reboot command failure restarts containers and preserves status'

printf '[unit] system package updater tests complete\n'
