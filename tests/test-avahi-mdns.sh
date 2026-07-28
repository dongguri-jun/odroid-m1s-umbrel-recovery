#!/usr/bin/env bash
set -Eeuo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

# shellcheck source=scripts/m1s-update-umbrel.sh
source scripts/m1s-update-umbrel.sh

fail() {
  printf '[avahi][FAIL] %s\n' "$1" >&2
  exit 1
}

pass() {
  printf '[avahi][PASS] %s\n' "$1"
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

assert_not_exists() {
  local path="$1"
  local label="$2"
  [[ ! -e "$path" && ! -L "$path" ]] || fail "$label: unexpectedly found '$path'"
}

TEST_TMPDIR="$(mktemp -d "${TMPDIR:-/tmp}/m1s-avahi-mdns.XXXXXX")"
trap 'rm -rf "$TEST_TMPDIR"' EXIT
FIXTURE_ROOT="$TEST_TMPDIR/fixture"
SYSTEMCTL_LOG="$TEST_TMPDIR/systemctl.log"
SYSTEMCTL_FAIL_UNIT=""

systemctl() {
  printf '%s\n' "$*" >> "$SYSTEMCTL_LOG"
  if [[ -n "$SYSTEMCTL_FAIL_UNIT" && "$*" == "restart $SYSTEMCTL_FAIL_UNIT" ]]; then
    return 55
  fi
  return 0
}

ip() {
  case "$*" in
    "route show default")
      printf 'default via 192.0.2.1 dev lan0 proto dhcp\n'
      ;;
    "-4 -o addr show dev lan0 scope global")
      printf '2: lan0    inet 192.0.2.10/24 brd 192.0.2.255 scope global lan0\n'
      ;;
    "-o link show")
      printf '1: lo: <LOOPBACK>\n2: lan0: <UP,MULTICAST>\n'
      ;;
    *)
      return 1
      ;;
  esac
}

reset_fixture() {
  rm -rf "$FIXTURE_ROOT"
  mkdir -p "$FIXTURE_ROOT/etc/avahi" "$FIXTURE_ROOT/usr/local/bin" "$FIXTURE_ROOT/etc/systemd/system"
  mkdir -p "$FIXTURE_ROOT/sys/class/net/docker0" "$FIXTURE_ROOT/sys/class/net/br-test" "$FIXTURE_ROOT/sys/class/net/veth-transient"
  M1S_AVAHI_CONF="$FIXTURE_ROOT/etc/avahi/avahi-daemon.conf"
  M1S_AVAHI_ALIAS_SCRIPT="$FIXTURE_ROOT/usr/local/bin/avahi-publish-umbrel"
  M1S_AVAHI_ALIAS_SERVICE="$FIXTURE_ROOT/etc/systemd/system/avahi-alias-umbrel.service"
  M1S_AVAHI_NET_DIR="$FIXTURE_ROOT/sys/class/net"
  M1S_AVAHI_RESTARTED=0
  M1S_AVAHI_CONFIG_CHANGED=0
  DRY_RUN=0
  SYSTEMCTL_FAIL_UNIT=""
  : > "$SYSTEMCTL_LOG"
  cat > "$M1S_AVAHI_CONF" <<'EOF'
[server]
allow-interfaces=wifi-wan0
#deny-interfaces=old-bridge
use-ipv4=yes

[publish]
publish-addresses=yes
EOF
}

count_systemctl_call() {
  local expected="$1"
  local count=0
  while IFS= read -r line; do
    [[ "$line" == "$expected" ]] && count=$((count + 1))
  done < "$SYSTEMCTL_LOG"
  printf '%s\n' "$count"
}

reset_fixture
rendered_config="$TEST_TMPDIR/rendered-avahi.conf"
m1s_render_avahi_config "$M1S_AVAHI_CONF" "$(m1s_collect_avahi_deny_interfaces)" > "$rendered_config"
expected_config="$TEST_TMPDIR/expected-avahi.conf"
cat > "$expected_config" <<'EOF'
[server]
#allow-interfaces=wifi-wan0
deny-interfaces=docker0,br-test
use-ipv4=yes

[publish]
publish-addresses=yes
EOF
cmp -s "$expected_config" "$rendered_config" || fail 'renderer did not produce the exact canonical Avahi config'
if grep -Eq '^[[:space:]]*allow-interfaces[[:space:]]*=' "$rendered_config"; then
  fail 'renderer left an active allow-interfaces setting'
fi
if grep -Eq '^[[:space:]]*deny-interfaces=.*veth' "$rendered_config"; then
  fail 'renderer enumerated a transient veth interface'
fi
pass 'renderer removes the stale pin and writes only present stable virtual bridges'

installer_alias_script="$TEST_TMPDIR/installer-alias-script"
updater_alias_script="$TEST_TMPDIR/updater-alias-script"
installer_alias_unit="$TEST_TMPDIR/installer-alias-unit"
updater_alias_unit="$TEST_TMPDIR/updater-alias-unit"
M1S_INSTALLER_LIB_ONLY=1 bash -c 'source scripts/m1s-clean-install-umbrel.sh; m1s_render_avahi_alias_script' > "$installer_alias_script"
bash -c 'source scripts/m1s-update-umbrel.sh; m1s_render_avahi_alias_script' > "$updater_alias_script"
M1S_INSTALLER_LIB_ONLY=1 bash -c 'source scripts/m1s-clean-install-umbrel.sh; m1s_render_avahi_alias_unit' > "$installer_alias_unit"
bash -c 'source scripts/m1s-update-umbrel.sh; m1s_render_avahi_alias_unit' > "$updater_alias_unit"
cmp -s "$installer_alias_script" "$updater_alias_script" || fail 'installer and updater alias scripts differ'
cmp -s "$installer_alias_unit" "$updater_alias_unit" || fail 'installer and updater alias units differ'
pass 'installer and updater render byte-identical alias scripts and units'

definition_counts="$(python3 - <<'PY'
from pathlib import Path
import re

text = "\n".join(path.read_text(encoding="utf-8") for path in Path("scripts").glob("*.sh"))
names = (
    "detect_lan_interface",
    "m1s_render_avahi_alias_script",
    "m1s_render_avahi_alias_unit",
)
print(" ".join(str(len(re.findall(rf"(?m)^{name}\(\) \{{", text))) for name in names))
PY
)"
assert_eq "1 1 1" "$definition_counts" 'shared Avahi definitions must each exist exactly once'
if grep -q 'eth0' scripts/m1s-avahi-mdns.sh; then
  fail 'shared Avahi path hardcodes eth0'
fi
pass 'shared helper is the single definition source and has no fixed LAN interface'

reset_fixture
apply_output="$(apply_0_5_28_to_0_5_29 2>&1)"
cmp -s "$expected_config" "$M1S_AVAHI_CONF" || fail 'migration did not remove the stale pin'
assert_eq "1" "$(count_systemctl_call 'restart avahi-daemon.service')" 'first changed migration Avahi restart count'
assert_eq "1" "$(count_systemctl_call 'restart avahi-alias-umbrel.service')" 'first migration alias restart count'
assert_contains "$apply_output" 'docker0,br-test' 'migration reports the concrete deny list'
apply_0_5_28_to_0_5_29 >/dev/null
assert_eq "1" "$(count_systemctl_call 'restart avahi-daemon.service')" 'idempotent migration Avahi restart count'
assert_eq "2" "$(count_systemctl_call 'restart avahi-alias-umbrel.service')" 'idempotent migration alias restart count'
pass 'migration removes a stale pin and restarts Avahi only for an actual config change'

reset_fixture
dry_snapshot="$TEST_TMPDIR/dry-snapshot"
cp -a "$FIXTURE_ROOT" "$dry_snapshot"
DRY_RUN=1
dry_output="$(apply_0_5_28_to_0_5_29 2>&1)"
DRY_RUN=0
diff -r "$dry_snapshot" "$FIXTURE_ROOT" >/dev/null || fail 'DRY_RUN changed the fixture tree'
assert_eq "" "$(<"$SYSTEMCTL_LOG")" 'DRY_RUN systemctl execution log'
assert_contains "$dry_output" 'restart avahi-daemon.service' 'DRY_RUN reports the required full Avahi restart'
pass 'DRY_RUN reports the repair without mutating config, alias files, or services'

reset_fixture
SYSTEMCTL_FAIL_UNIT="avahi-daemon.service"
restart_output="$TEST_TMPDIR/restart-failure.out"
if apply_0_5_28_to_0_5_29 > "$restart_output" 2>&1; then
  fail 'migration accepted a failed Avahi restart'
fi
restart_text="$(<"$restart_output")"
assert_contains "$restart_text" 'Use http://192.0.2.10' 'restart failure prints the device-IP fallback'
assert_contains "$restart_text" 'Manual recovery command: sudo systemctl restart avahi-daemon.service' 'restart failure prints the exact recovery command'
assert_not_exists "$M1S_AVAHI_ALIAS_SCRIPT" 'failed Avahi restart must stop before alias rewrite'
pass 'restart failure is loud, leaves Docker untouched, and prints manual recovery'

reset_fixture
clean_health_config="$TEST_TMPDIR/clean-health-avahi.conf"
m1s_render_avahi_config "$M1S_AVAHI_CONF" "$(m1s_collect_avahi_deny_interfaces)" > "$clean_health_config"
mv "$clean_health_config" "$M1S_AVAHI_CONF"
health_output="$TEST_TMPDIR/health.out"
run_health_check() {
  M1S_AVAHI_CONF="$M1S_AVAHI_CONF" \
  M1S_AVAHI_NET_DIR="$M1S_AVAHI_NET_DIR" \
  M1S_INSTALLER_LIB_ONLY=1 \
  bash -s > "$health_output" 2>&1 <<'BASH'
set -Eeuo pipefail
source scripts/m1s-clean-install-umbrel.sh
TARGET_PARTITION=/dev/test-data
DATA_DIR=/mnt/test-data
get_exact_data_mount_source() { printf '/dev/test-data\n'; }
systemctl() {
  case "$*" in
    "is-active docker"|"is-active avahi-daemon"|"is-active avahi-alias-umbrel.service") printf 'active\n' ;;
    "is-enabled avahi-daemon.service") return 0 ;;
    *) return 1 ;;
  esac
}
docker() { printf 'running\n'; }
getent() { return 1; }
curl() { [[ "$*" != *"http://umbrel.local"* ]]; }
ip() {
  case "$*" in
    "route show default") printf 'default via 192.0.2.1 dev lan0\n' ;;
    "-4 -o addr show dev lan0 scope global") printf '2: lan0 inet 192.0.2.10/24 scope global lan0\n' ;;
    *) return 1 ;;
  esac
}
avahi-daemon() { :; }
report_install_health lan0 192.0.2.10
BASH
}

run_health_check || fail 'clean config with working device-IP HTTP must not fail on external mDNS resolution'
health_text="$(<"$health_output")"
assert_contains "$health_text" 'mDNS config self-check: clean' 'health report separates managed config truth'
assert_contains "$health_text" 'External mDNS resolution failed while HTTP by device IP succeeded' 'health report classifies client-side mDNS failure as warning-only'

printf 'allow-interfaces=wifi-wan0\n' >> "$M1S_AVAHI_CONF"
if run_health_check; then
  fail 'health check accepted an active allow-interfaces setting'
fi
health_text="$(<"$health_output")"
assert_contains "$health_text" 'mDNS config self-check: failed' 'health report exposes managed configuration failure'
assert_contains "$health_text" 'managed mDNS configuration is not canonical' 'managed mDNS failure is fatal'
pass 'health check makes managed misconfiguration fatal and external mDNS failure warning-only'

printf '[avahi] mDNS tests complete\n'
