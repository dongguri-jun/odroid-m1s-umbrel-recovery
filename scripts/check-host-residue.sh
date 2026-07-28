#!/usr/bin/env bash
# Host residue detector.
#
# Question it answers:
#   "Does this host carry anything that neither the OS packages nor this
#    repository's own scripts put there, and whose fault is it?"
#
# Core rule:
#   unowned = file in a watched directory
#             AND no dpkg package owns it
#             AND this repository's public scripts do not create it
#
# Unowned files are then classified by provenance, because "unowned" alone is
# too noisy to gate on. Only the classes WE are responsible for fail the gate.
#
#   ours-orphan   our own naming, not in the manifest -> abandoned experiment
#   ours-backup   our own .bak.<stamp> family exceeds bounded retention
#   settings-drift settings written by this project no longer match intent or runtime reality
#   third-party   somebody else's service the installer deliberately preserves
#   os-generated  produced by snapd or shipped in the OS image
#
# Read-only. This script never modifies the host.
set -uo pipefail

# Default to the repository this script lives in, so the tool works regardless of
# where the checkout is or which account owns it. Override with the REPOSITORY
# argument when auditing a host from a checkout elsewhere.
REPO="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
ROOT="/"
repo_argument_seen=0

usage() {
  printf 'Usage: %s [--root DIR] [REPOSITORY]\n' "${0##*/}"
}

while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --root)
      [[ "$#" -ge 2 ]] || { printf 'FATAL: --root requires a directory\n' >&2; exit 2; }
      ROOT="$2"
      shift 2
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    --*)
      printf 'FATAL: unknown option: %s\n' "$1" >&2
      exit 2
      ;;
    *)
      [[ "$repo_argument_seen" -eq 0 ]] || { printf 'FATAL: only one repository path is allowed\n' >&2; exit 2; }
      REPO="$1"
      repo_argument_seen=1
      shift
      ;;
  esac
done

ROOT="${ROOT%/}"
[[ -n "$ROOT" ]] || ROOT="/"
[[ -d "$ROOT" ]] || { printf 'FATAL: no root directory at %s\n' "$ROOT" >&2; exit 2; }
[[ -d "$REPO/scripts" ]] || { printf 'FATAL: no scripts at %s\n' "$REPO/scripts" >&2; exit 2; }

AVAHI_HELPER="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/m1s-avahi-mdns.sh"
[[ -r "$AVAHI_HELPER" ]] || { printf 'FATAL: cannot read Avahi helper at %s\n' "$AVAHI_HELPER" >&2; exit 2; }
# shellcheck source=scripts/m1s-avahi-mdns.sh
source "$AVAHI_HELPER"

RETENTION_HELPER="$REPO/scripts/m1s-backup-retention.sh"

derive_backup_retention_count() {
  local helper_path="$1"
  local -a retention_counts=()

  if [[ ! -r "$helper_path" ]]; then
    printf 'FATAL: cannot read backup retention helper at %s\n' "$helper_path" >&2
    return 1
  fi
  mapfile -t retention_counts < <(
    sed -nE 's/^M1S_BACKUP_RETENTION_COUNT="\$\{M1S_BACKUP_RETENTION_COUNT:-([1-9][0-9]*)\}"$/\1/p' "$helper_path"
  )
  if [[ "${#retention_counts[@]}" -ne 1 ]]; then
    printf 'FATAL: could not derive one M1S_BACKUP_RETENTION_COUNT default from %s\n' "$helper_path" >&2
    return 1
  fi
  printf '%s' "${retention_counts[0]}"
}

if ! BACKUP_RETENTION_BOUND="$(derive_backup_retention_count "$RETENTION_HELPER")"; then
  exit 2
fi

ORPHAN=0
BACKUP=0
BACKUP_INFO=0
THIRD=0
OSGEN=0
DRIFT=0

BROAD_SHARED_DIRS=(
  # These roots mix repository-managed files with substantial unrelated system state.
  /boot /etc /usr/local
)

EXPLICIT_HIGH_RISK_DIRS=(
  # Network configuration residue has caused real connectivity failures outside current manifest paths.
  /etc/NetworkManager /etc/NetworkManager/conf.d /etc/NetworkManager/system-connections /etc/netplan
  # Unmanaged privilege, scheduled-task, and kernel-policy snippets are always worth surfacing.
  /etc/sudoers.d /etc/cron.d /etc/modprobe.d /etc/sysctl.d
)

BROAD_OS_GENERATED_EXACT_PATHS=(
  /boot/boot-logo.bmp.gz /boot/boot.scr
)

rooted_path() {
  if [[ "$ROOT" == "/" ]]; then
    printf '%s' "$1"
  else
    printf '%s%s' "$ROOT" "$1"
  fi
}

host_path() {
  if [[ "$ROOT" == "/" ]]; then
    printf '%s' "$1"
  else
    printf '%s' "${1#"$ROOT"}"
  fi
}

is_broad_shared_dir() {
  local candidate_dir="$1"
  local broad_dir
  for broad_dir in "${BROAD_SHARED_DIRS[@]}"; do
    [[ "$candidate_dir" == "$broad_dir" ]] && return 0
  done
  return 1
}

# Short, reviewable list of things the OS itself generates or ships.
# Kept explicit on purpose: a fuzzy heuristic here would hide real residue.
is_os_generated() {
  local path="$1"
  local basename="${1##*/}"
  local generated_path
  [[ "$basename" =~ ^snap-.+\.mount$ ]] && return 0
  for generated_path in "${BROAD_OS_GENERATED_EXACT_PATHS[@]}"; do
    [[ "$path" == "$generated_path" ]] && return 0
  done
  [[ "$path" =~ ^/boot/initrd\.img-[0-9]+\.[0-9]+\.[0-9]+-odroid-arm64$ ]] && return 0
  case "$path" in
    /etc/default/console-setup|/etc/default/cpufrequtils|/etc/default/gpufrequtils|/etc/default/keyboard|/etc/default/locale|/etc/default/mdadm)
      return 0
      ;;
  esac
  [[ "$path" == /etc/netplan/01-netcfg.yaml ]] && return 0
  [[ "$path" == /etc/sysctl.d/99-cloudimg-ipv6.conf ]] && return 0
  return 1
}

# Names this project owns. Anything matching these is OURS, so if it is not in
# the manifest it is our own abandoned artefact, not a third party's.
# Substring rather than prefix: drop-in config dirs use an NN- ordering prefix,
# e.g. 90-m1s-wifi.conf, which a prefix test silently misclassifies.
is_ours() {
  local basename="${1##*/}"
  [[ "$basename" == *m1s-* || "$basename" == *fullnode-* || "$basename" == *umbrel* ]]
}

is_our_backup() {
  local basename="${1##*/}"
  [[ "$basename" =~ \.bak(\.|$) && "$basename" =~ \.[0-9]+$ ]]
}

backup_family_key() {
  local path="$1"
  if [[ "$path" =~ ^(.*\.)[0-9]+$ ]]; then
    printf '%s' "${BASH_REMATCH[1]}"
  else
    printf '%s' "$path"
  fi
}

package_owns_path() {
  local path="$1"
  if [[ -n "${M1S_RESIDUE_OWNERSHIP_QUERY_COMMAND:-}" ]]; then
    "$M1S_RESIDUE_OWNERSHIP_QUERY_COMMAND" "$path" >/dev/null 2>&1
  else
    dpkg -S "$path" >/dev/null 2>&1
  fi
}

query_failed_units() {
  if [[ -n "${M1S_RESIDUE_SYSTEMD_QUERY_COMMAND:-}" ]]; then
    "$M1S_RESIDUE_SYSTEMD_QUERY_COMMAND"
  else
    systemctl list-units --state=failed --no-legend --plain --no-pager
  fi
}

query_static_hostname() {
  if [[ -n "${M1S_RESIDUE_HOSTNAME_QUERY_COMMAND:-}" ]]; then
    "$M1S_RESIDUE_HOSTNAME_QUERY_COMMAND"
  else
    hostnamectl --static 2>/dev/null || hostname
  fi
}

query_uuid_device() {
  local uuid="$1"
  local device
  if [[ -n "${M1S_RESIDUE_UUID_QUERY_COMMAND:-}" ]]; then
    "$M1S_RESIDUE_UUID_QUERY_COMMAND" "$uuid"
  else
    device="$(blkid -U "$uuid")" || return 1
    [[ -b "$device" ]] || return 1
    printf '%s\n' "$device"
  fi
}

comma_join() {
  local result=""
  local value
  for value in "$@"; do
    if [[ -n "$result" ]]; then
      result+=", "
    fi
    result+="$value"
  done
  printf '%s' "$result"
}

record_setting_drift() {
  local kind="$1"
  local path="$2"
  local name="$3"
  local expected="$4"
  local observed="$5"
  local reason="$6"
  L_DRIFT+=("[$kind] $name ($path) | expected: $expected | observed: $observed | reason: $reason")
  DRIFT=$((DRIFT + 1))
}

check_hostname_setting() {
  local kind="$1" path="$2" name="$3"
  local observed_hostname
  observed_hostname="$(query_static_hostname 2>/dev/null || true)"
  [[ -n "$observed_hostname" ]] || observed_hostname="<unavailable>"
  if [[ "$observed_hostname" != "$EXPECTED_HOSTNAME" ]]; then
    record_setting_drift \
      "$kind" "$path" "$name" \
      "hostname=$EXPECTED_HOSTNAME" \
      "hostname=$observed_hostname" \
      'the managed hostname anchors the umbrel.local identity'
  fi
}

check_hosts_mapping_setting() {
  local kind="$1" path="$2" name="$3"
  local config_file
  local observed_mapping
  local -a mappings=()
  config_file="$(rooted_path "$path")"
  if [[ -f "$config_file" ]]; then
    mapfile -t mappings < <(
      awk -v address="$EXPECTED_HOSTS_ADDRESS" '
        $1 == address {
          mapping = ""
          for (field = 2; field <= NF; field++) {
            mapping = mapping (mapping == "" ? "" : " ") $field
          }
          print mapping
        }
      ' "$config_file"
    )
  fi
  observed_mapping="$(comma_join "${mappings[@]}")"
  [[ -n "$observed_mapping" ]] || observed_mapping="<absent>"
  if [[ "${#mappings[@]}" -ne 1 || "${mappings[0]:-}" != "$EXPECTED_HOSTNAME" ]]; then
    record_setting_drift \
      "$kind" "$path" "$name" \
      "$EXPECTED_HOSTS_ADDRESS maps exactly to $EXPECTED_HOSTNAME" \
      "$EXPECTED_HOSTS_ADDRESS maps to $observed_mapping" \
      'Debian host identity and local name resolution must agree'
  fi
}

read_docker_log_settings() {
  local config_file="$1"
  python3 - "$config_file" <<'PY'
from pathlib import Path
import json
import sys

path = Path(sys.argv[1])
if not path.is_file():
    print("<missing file>")
    raise SystemExit(0)
try:
    config = json.loads(path.read_text(encoding="utf-8"))
except (OSError, json.JSONDecodeError) as error:
    print(f"<invalid JSON: {type(error).__name__}>")
    raise SystemExit(0)
log_options = config.get("log-opts")
if not isinstance(log_options, dict):
    log_options = {}
print(
    "log-driver={}, max-size={}, max-file={}".format(
        config.get("log-driver", "<missing>"),
        log_options.get("max-size", "<missing>"),
        log_options.get("max-file", "<missing>"),
    )
)
PY
}

check_docker_log_settings() {
  local kind="$1" path="$2" name="$3"
  local expected observed
  expected="log-driver=$EXPECTED_DOCKER_LOG_DRIVER, max-size=$EXPECTED_DOCKER_MAX_SIZE, max-file=$EXPECTED_DOCKER_MAX_FILE"
  observed="$(read_docker_log_settings "$(rooted_path "$path")")"
  if [[ "$observed" != "$expected" ]]; then
    record_setting_drift \
      "$kind" "$path" "$name" \
      "$expected" "$observed" \
      'bounded json-file logs prevent Docker logs from exhausting the host disk'
  fi
}

check_docker_mount_requirement() {
  local kind="$1" path="$2" name="$3"
  local config_file expected observed
  local -a values=()
  config_file="$(rooted_path "$path")"
  expected="RequiresMountsFor=$EXPECTED_DATA_DIR"
  if [[ -f "$config_file" ]]; then
    mapfile -t values < <(
      sed -nE 's/^[[:space:]]*RequiresMountsFor[[:space:]]*=[[:space:]]*(.*[^[:space:]])[[:space:]]*$/\1/p' "$config_file"
    )
  fi
  observed="$(comma_join "${values[@]}")"
  [[ -n "$observed" ]] && observed="RequiresMountsFor=$observed" || observed="<absent>"
  if [[ "${#values[@]}" -ne 1 || "${values[0]:-}" != "$EXPECTED_DATA_DIR" ]]; then
    record_setting_drift \
      "$kind" "$path" "$name" \
      "$expected" "$observed" \
      'Docker starting without the data mount can write Umbrel data to the root filesystem'
  fi
}

check_avahi_allow_interfaces() {
  local kind="$1" path="$2" name="$3"
  local allow_key='allow-interfaces'
  local config_file observed
  local -a active_allow=()
  config_file="$(rooted_path "$path")"
  if [[ ! -f "$config_file" ]]; then
    record_setting_drift \
      "$kind" "$path" "$name" \
      'no active allow-interfaces' '<missing file>' \
      'active interface pinning can exclude the live LAN and break umbrel.local'
    return
  fi
  if ! m1s_validate_avahi_allow_interfaces "$config_file" 2>/dev/null; then
    mapfile -t active_allow < <(m1s_collect_active_avahi_setting_values "$config_file" allow-interfaces)
    observed="$allow_key=$(comma_join "${active_allow[@]}")"
    record_setting_drift \
      "$kind" "$path" "$name" \
      'no active allow-interfaces' "$observed" \
      'active interface pinning can exclude the live LAN and break umbrel.local'
  fi
}

check_avahi_deny_interfaces() {
  local kind="$1" path="$2" name="$3"
  local config_file expected_deny observed
  local -a active_deny=()
  config_file="$(rooted_path "$path")"
  expected_deny="$(m1s_collect_avahi_deny_interfaces)"
  if [[ ! -f "$config_file" ]]; then
    record_setting_drift \
      "$kind" "$path" "$name" \
      "deny-interfaces contains only present virtual bridges: ${expected_deny:-<none>}" \
      '<missing file>' \
      'stale or physical-interface exclusions can suppress mDNS on a usable network'
    return
  fi
  if ! m1s_validate_avahi_deny_interfaces "$config_file" "$expected_deny" 2>/dev/null; then
    mapfile -t active_deny < <(m1s_collect_active_avahi_setting_values "$config_file" deny-interfaces)
    observed="deny-interfaces=$(comma_join "${active_deny[@]}")"
    [[ "$observed" != 'deny-interfaces=' ]] || observed='deny-interfaces=<absent>'
    record_setting_drift \
      "$kind" "$path" "$name" \
      "deny-interfaces contains only present virtual bridges: ${expected_deny:-<none>}" \
      "$observed" \
      'stale or physical-interface exclusions can suppress mDNS on a usable network'
  fi
}

check_avahi_default_route() {
  local kind="$1" path="$2" name="$3"
  local config_file default_interface observed
  local -a denied_interfaces=()
  config_file="$(rooted_path "$path")"
  [[ -f "$config_file" ]] || return
  default_interface="$(m1s_default_route_interface 2>/dev/null || true)"
  [[ -n "$default_interface" ]] || return
  if m1s_avahi_interface_is_denied "$config_file" "$default_interface" 2>/dev/null; then
    mapfile -t denied_interfaces < <(m1s_collect_avahi_denied_interfaces "$config_file")
    observed="deny-interfaces=$(comma_join "${denied_interfaces[@]}")"
    record_setting_drift \
      "$kind" "$path" "$name" \
      "default-route interface $default_interface is not denied" \
      "$observed" \
      'denying the live LAN prevents Avahi from publishing umbrel.local there'
  fi
}

check_fullnode_fstab_uuid() {
  local kind="$1" path="$2" name="$3"
  local config_file source uuid
  local -a sources=()
  config_file="$(rooted_path "$path")"
  if [[ -f "$config_file" ]]; then
    mapfile -t sources < <(
      awk -v mountpoint="$EXPECTED_DATA_DIR" '
        /^[[:space:]]*#/ || NF < 2 { next }
        $2 == mountpoint { print $1 }
      ' "$config_file"
    )
  fi
  if [[ "${#sources[@]}" -eq 0 ]]; then
    record_setting_drift \
      "$kind" "$path" "$name" \
      "UUID for $EXPECTED_DATA_DIR resolves to a present block device" \
      "no active $EXPECTED_DATA_DIR fstab entry" \
      'a missing data-mount entry leaves Umbrel storage unavailable after boot'
    return
  fi
  for source in "${sources[@]}"; do
    if [[ "$source" != UUID=* ]]; then
      record_setting_drift \
        "$kind" "$path" "$name" \
        "UUID for $EXPECTED_DATA_DIR resolves to a present block device" \
        "$source is not a UUID reference" \
        'the data mount must follow the filesystem identity rather than a replaceable device path'
      continue
    fi
    uuid="${source#UUID=}"
    uuid="${uuid#\"}"
    uuid="${uuid%\"}"
    if ! query_uuid_device "$uuid" >/dev/null 2>&1; then
      record_setting_drift \
        "$kind" "$path" "$name" \
        "UUID for $EXPECTED_DATA_DIR resolves to a present block device" \
        "UUID=$uuid resolves to no present block device" \
        'a dead data-mount UUID leaves Umbrel storage unavailable after boot'
    fi
  done
}

EXPECTED="$(mktemp)"
trap 'rm -f "$EXPECTED"' EXIT
grep -rhoE --include='*.sh' --exclude='check-host-residue.sh' '/(boot|etc|usr/local)/[A-Za-z0-9._/-]+' "$REPO/scripts" 2>/dev/null \
  | sed 's/[".,;)]*$//' | sort -u > "$EXPECTED"

SETTING_DRIFT_RULES=(
  # Host identity must stay aligned with the name advertised as umbrel.local.
  'static|/etc/hosts|hostname'
  # Debian local-host resolution must map the managed host identity consistently.
  'static|/etc/hosts|hosts-loopback'
  # Bounded Docker JSON logs protect the host filesystem from unbounded growth.
  'static|/etc/docker/daemon.json|docker-log-rotation'
  # Docker must not start before the Umbrel data filesystem is mounted.
  'static|/etc/systemd/system/docker.service.d/require-fullnode.conf|docker-fullnode-requirement'
  # An active Avahi allow-list can silently exclude the interface serving the LAN.
  'static|/etc/avahi/avahi-daemon.conf|avahi-allow-interfaces'
  # Avahi exclusions are valid only for virtual bridges observed on this boot.
  'runtime|/etc/avahi/avahi-daemon.conf|avahi-deny-interfaces'
  # The interface carrying the default IPv4 route must always receive mDNS traffic.
  'runtime|/etc/avahi/avahi-daemon.conf|avahi-default-route'
  # The persisted Umbrel data mount must still resolve after SSD replacement or reformatting.
  'runtime|/etc/fstab|fullnode-fstab-uuid'
)

assert_setting_rule_paths_in_manifest() {
  local rule kind path name
  for rule in "${SETTING_DRIFT_RULES[@]}"; do
    IFS='|' read -r kind path name <<< "$rule"
    if ! grep -qxF "$path" "$EXPECTED"; then
      printf 'FATAL: settings-drift rule %s references %s, which is absent from the derived manifest\n' "$name" "$path" >&2
      return 1
    fi
  done
}

derive_managed_setting_values() {
  python3 - "$REPO/scripts" <<'PY'
from pathlib import Path
import json
import re
import sys

scripts_dir = Path(sys.argv[1])
text = "\n".join(path.read_text(encoding="utf-8") for path in sorted(scripts_dir.glob("*.sh")))

def one_value(label, values):
    unique = sorted(set(values))
    if len(unique) != 1:
        raise SystemExit(f"could not derive one {label}: {unique!r}")
    return unique[0]

hostname = one_value(
    "managed hostname",
    re.findall(r'(?m)^(?:UMBREL_HOSTNAME|FIXED_HOSTNAME)="([^"]+)"$', text),
)
data_dir = one_value("Umbrel data directory", re.findall(r'(?m)^DATA_DIR="([^"]+)"$', text))
hosts_address = one_value(
    "managed /etc/hosts address",
    re.findall(r"printf\s+'([0-9]+(?:\.[0-9]+){3})\\t%s\\n'", text),
)

docker_settings = []
decoder = json.JSONDecoder()
for position, character in enumerate(text):
    if character != "{":
        continue
    try:
        candidate, _ = decoder.raw_decode(text[position:])
    except json.JSONDecodeError:
        continue
    if not isinstance(candidate, dict) or "log-driver" not in candidate:
        continue
    log_options = candidate.get("log-opts")
    if not isinstance(log_options, dict):
        continue
    if "max-size" in log_options and "max-file" in log_options:
        docker_settings.append(
            (str(candidate["log-driver"]), str(log_options["max-size"]), str(log_options["max-file"]))
        )

docker_driver, docker_max_size, docker_max_file = one_value("Docker log settings", docker_settings)
print("\t".join((hostname, hosts_address, data_dir, docker_driver, docker_max_size, docker_max_file)))
PY
}

assert_setting_rule_paths_in_manifest || exit 2
if ! MANAGED_SETTING_VALUES="$(derive_managed_setting_values)"; then
  printf 'FATAL: could not derive managed settings from %s\n' "$REPO/scripts" >&2
  exit 2
fi
IFS=$'\t' read -r \
  EXPECTED_HOSTNAME \
  EXPECTED_HOSTS_ADDRESS \
  EXPECTED_DATA_DIR \
  EXPECTED_DOCKER_LOG_DRIVER \
  EXPECTED_DOCKER_MAX_SIZE \
  EXPECTED_DOCKER_MAX_FILE \
  <<< "$MANAGED_SETTING_VALUES"

derive_full_scan_dirs() {
  local manifest_path parent_dir candidate_dir
  {
    while IFS= read -r manifest_path; do
      parent_dir="${manifest_path%/*}"
      while [[ "$parent_dir" == /boot || "$parent_dir" == /boot/* \
        || "$parent_dir" == /etc || "$parent_dir" == /etc/* \
        || "$parent_dir" == /usr/local || "$parent_dir" == /usr/local/* ]]; do
        printf '%s\n' "$parent_dir"
        parent_dir="${parent_dir%/*}"
      done
    done < "$EXPECTED"
    printf '%s\n' "${EXPLICIT_HIGH_RISK_DIRS[@]}"
  } | while IFS= read -r candidate_dir; do
    is_broad_shared_dir "$candidate_dir" || printf '%s\n' "$candidate_dir"
  done | sort -u
}

mapfile -t FULL_SCAN_DIRS < <(derive_full_scan_dirs)

expected_path() {
  grep -qxF "$1" "$EXPECTED" && return 0
  local basename="${1##*/}"
  grep -qE "/${basename//./\\.}\$" "$EXPECTED"
}

printf '=== manifest derived from the repository scripts: %s paths ===\n\n' "$(wc -l < "$EXPECTED")"

declare -a L_ORPHAN=()
declare -a L_BACKUP_FAIL=()
declare -a L_BACKUP_INFO=()
declare -a BACKUP_FAMILIES=()
declare -a L_THIRD=()
declare -a L_OSGEN=()
declare -a L_DRIFT=()
declare -A BACKUP_FAMILY_COUNTS=()
declare -A SCANNED_LOGICAL_PATHS=()

classify_scanned_file() {
  local scanned_file="$1"
  local logical_path entry family_key

  [[ -L "$scanned_file" ]] && return 0
  logical_path="$(host_path "$scanned_file")"
  [[ -z "${SCANNED_LOGICAL_PATHS[$logical_path]+present}" ]] || return 0
  SCANNED_LOGICAL_PATHS["$logical_path"]=1
  package_owns_path "$logical_path" && return 0
  expected_path "$logical_path" && return 0
  entry="$logical_path  (mtime $(stat -c '%y' "$scanned_file" 2>/dev/null | cut -d. -f1))"
  if is_os_generated "$logical_path"; then
    L_OSGEN+=("$entry")
    OSGEN=$((OSGEN + 1))
  elif is_our_backup "$logical_path"; then
    family_key="$(backup_family_key "$logical_path")"
    if [[ -z "${BACKUP_FAMILY_COUNTS[$family_key]+present}" ]]; then
      BACKUP_FAMILIES+=("$family_key")
      BACKUP_FAMILY_COUNTS["$family_key"]=0
    fi
    BACKUP_FAMILY_COUNTS["$family_key"]=$((BACKUP_FAMILY_COUNTS["$family_key"] + 1))
  elif is_ours "$logical_path"; then
    L_ORPHAN+=("$entry")
    ORPHAN=$((ORPHAN + 1))
  else
    L_THIRD+=("$entry")
    THIRD=$((THIRD + 1))
  fi
}

for host_dir in "${FULL_SCAN_DIRS[@]}"; do
  scan_dir="$(rooted_path "$host_dir")"
  [[ -d "$scan_dir" ]] || continue
  while IFS= read -r scanned_file; do
    classify_scanned_file "$scanned_file"
  done < <(find "$scan_dir" -maxdepth 2 -type f 2>/dev/null | sort)
done

for logical_path in "${BROAD_OS_GENERATED_EXACT_PATHS[@]}"; do
  scanned_file="$(rooted_path "$logical_path")"
  [[ -f "$scanned_file" ]] || continue
  classify_scanned_file "$scanned_file"
done

scan_dir="$(rooted_path /boot)"
if [[ -d "$scan_dir" ]]; then
  while IFS= read -r scanned_file; do
    logical_path="$(host_path "$scanned_file")"
    is_os_generated "$logical_path" || continue
    classify_scanned_file "$scanned_file"
  done < <(find "$scan_dir" -maxdepth 1 -type f -name 'initrd.img-*-odroid-arm64' 2>/dev/null | sort)
fi

while IFS= read -r manifest_path; do
  manifest_dir="${manifest_path%/*}"
  is_broad_shared_dir "$manifest_dir" || continue
  scan_dir="$(rooted_path "$manifest_dir")"
  [[ -d "$scan_dir" ]] || continue
  manifest_basename="${manifest_path##*/}"
  while IFS= read -r scanned_file; do
    classify_scanned_file "$scanned_file"
  done < <(
    find "$scan_dir" -maxdepth 1 -type f \
      \( -name "$manifest_basename.bak" -o -name "$manifest_basename.bak.*" -o -name "$manifest_basename.pre-*" \) \
      2>/dev/null | sort
  )
done < "$EXPECTED"

for family_key in "${BACKUP_FAMILIES[@]}"; do
  family_count="${BACKUP_FAMILY_COUNTS[$family_key]}"
  if ((family_count > BACKUP_RETENTION_BOUND)); then
    family_over=$((family_count - BACKUP_RETENTION_BOUND))
    L_BACKUP_FAIL+=("$family_key  (count $family_count, bound $BACKUP_RETENTION_BOUND, over $family_over)")
    BACKUP=$((BACKUP + 1))
  else
    L_BACKUP_INFO+=("$family_key  (count $family_count, bound $BACKUP_RETENTION_BOUND)")
    BACKUP_INFO=$((BACKUP_INFO + 1))
  fi
done

M1S_AVAHI_NET_DIR="$(rooted_path /sys/class/net)"
for setting_rule in "${SETTING_DRIFT_RULES[@]}"; do
  IFS='|' read -r rule_kind rule_path rule_name <<< "$setting_rule"
  case "$rule_name" in
    hostname) check_hostname_setting "$rule_kind" "$rule_path" "$rule_name" ;;
    hosts-loopback) check_hosts_mapping_setting "$rule_kind" "$rule_path" "$rule_name" ;;
    docker-log-rotation) check_docker_log_settings "$rule_kind" "$rule_path" "$rule_name" ;;
    docker-fullnode-requirement) check_docker_mount_requirement "$rule_kind" "$rule_path" "$rule_name" ;;
    avahi-allow-interfaces) check_avahi_allow_interfaces "$rule_kind" "$rule_path" "$rule_name" ;;
    avahi-deny-interfaces) check_avahi_deny_interfaces "$rule_kind" "$rule_path" "$rule_name" ;;
    avahi-default-route) check_avahi_default_route "$rule_kind" "$rule_path" "$rule_name" ;;
    fullnode-fstab-uuid) check_fullnode_fstab_uuid "$rule_kind" "$rule_path" "$rule_name" ;;
    *) printf 'FATAL: unknown settings-drift rule: %s\n' "$rule_name" >&2; exit 2 ;;
  esac
done

show() {
  local title="$1"
  shift
  printf '%s\n' "$title"
  if [[ "$#" -eq 0 ]]; then
    printf '  (none)\n\n'
  else
    printf '  %s\n' "$@"
    printf '\n'
  fi
}

show "### FAIL: our own abandoned artefacts (${ORPHAN})" "${L_ORPHAN[@]}"
show "### FAIL: our backup families over retention bound (${BACKUP})" "${L_BACKUP_FAIL[@]}"
show "### INFO: our backup families within retention bound (${BACKUP_INFO})" "${L_BACKUP_INFO[@]}"
show "### FAIL: settings drift (${DRIFT})" "${L_DRIFT[@]}"
show "### REPORT ONLY: third-party, installer preserves (${THIRD})" "${L_THIRD[@]}"
show "### INFO: OS-generated (${OSGEN})" "${L_OSGEN[@]}"

printf '### FAIL: failed units\n'
FAILED="$(query_failed_units 2>/dev/null | cut -d' ' -f1)"
FAILCOUNT=0
if [[ -n "$FAILED" ]]; then
  while IFS= read -r unit; do
    if [[ -n "$unit" ]]; then
      printf '  %s\n' "$unit"
      FAILCOUNT=$((FAILCOUNT + 1))
    fi
  done <<< "$FAILED"
else
  printf '  (none)\n'
fi

GATE=$((ORPHAN + BACKUP + DRIFT + FAILCOUNT))
printf '\n=== gate-failing: %s (orphan %s, backups %s, failed units %s) | settings-drift %s | report-only: third-party %s, os %s ===\n' \
  "$GATE" "$ORPHAN" "$BACKUP" "$FAILCOUNT" "$DRIFT" "$THIRD" "$OSGEN"
exit $((GATE > 0 ? 1 : 0))
