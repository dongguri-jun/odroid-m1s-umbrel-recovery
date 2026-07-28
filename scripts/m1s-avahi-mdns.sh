#!/usr/bin/env bash

: "${M1S_AVAHI_CONF:=/etc/avahi/avahi-daemon.conf}"
: "${M1S_AVAHI_ALIAS_SCRIPT:=/usr/local/bin/avahi-publish-umbrel}"
: "${M1S_AVAHI_ALIAS_SERVICE:=/etc/systemd/system/avahi-alias-umbrel.service}"
: "${M1S_AVAHI_NET_DIR:=/sys/class/net}"
: "${M1S_AVAHI_RESTARTED:=0}"

M1S_AVAHI_CONFIG_CHANGED=0
M1S_AVAHI_FILE_CHANGED=0

m1s_avahi_info() {
  if declare -F info >/dev/null 2>&1; then
    info "$1"
  else
    printf '[INFO] %s\n' "$1"
  fi
}

m1s_avahi_error() {
  if declare -F err >/dev/null 2>&1; then
    err "$1"
  else
    printf '[ERROR] %s\n' "$1" >&2
  fi
}

m1s_default_route_interface() {
  if [[ -n "${M1S_AVAHI_DEFAULT_ROUTE_QUERY_COMMAND:-}" ]]; then
    "$M1S_AVAHI_DEFAULT_ROUTE_QUERY_COMMAND"
  else
    ip route show default 2>/dev/null | awk '/default/ {print $5; exit}'
  fi
}

m1s_is_lan_interface() {
  local iface="${1:-}"
  [[ -n "$iface" && "$iface" != lo && "$iface" != docker* && "$iface" != br-* && "$iface" != veth* && "$iface" != tailscale* && "$iface" != virbr* && "$iface" != zt* ]]
}

detect_lan_interface() {
  local iface=""

  iface="$(m1s_default_route_interface || true)"
  if m1s_is_lan_interface "$iface"; then
    printf '%s\n' "$iface"
    return 0
  fi

  iface="$(ip -o link show 2>/dev/null | awk -F': ' '$2 !~ /^(lo|docker.*|br-.*|veth.*|tailscale.*|virbr.*|zt.*)$/ {print $2; exit}' || true)"
  [[ -n "$iface" ]] || return 1
  printf '%s\n' "$iface"
}

m1s_interface_ipv4() {
  local iface="$1"
  [[ -n "$iface" ]] || return 1
  ip -4 -o addr show dev "$iface" scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -n1
}

m1s_alias_publish_ipv4() {
  local iface
  iface="$(m1s_default_route_interface || true)"
  [[ -n "$iface" ]] || return 1
  m1s_interface_ipv4 "$iface"
}

m1s_collect_avahi_deny_interfaces() {
  local net_dir="${1:-$M1S_AVAHI_NET_DIR}"
  local path
  local -a interfaces=()

  [[ -e "$net_dir/docker0" ]] && interfaces+=(docker0)
  for path in "$net_dir"/br-*; do
    [[ -e "$path" ]] || continue
    interfaces+=("${path##*/}")
  done

  if [[ "${#interfaces[@]}" -gt 0 ]]; then
    local IFS=,
    printf '%s\n' "${interfaces[*]}"
  fi
}

m1s_render_avahi_config() {
  local source_file="$1"
  local deny_interfaces="$2"

  python3 - "$source_file" "$deny_interfaces" <<'PY'
from pathlib import Path
import re
import sys

source_path = Path(sys.argv[1])
deny_interfaces = sys.argv[2]
text = source_path.read_text(encoding="utf-8")
lines = text.splitlines()
allow_key = "allow-interfaces"
deny_key = "deny-interfaces"
active_allow = re.compile(r"^(\s*)" + re.escape(allow_key) + r"\s*=")
active_deny = re.compile(r"^\s*" + re.escape(deny_key) + r"\s*=")
commented_deny = re.compile(r"^\s*#\s*" + re.escape(deny_key) + r"\s*=")
rendered = []
deny_written = False

for line in lines:
    allow_match = active_allow.match(line)
    if allow_match:
        indent = allow_match.group(1)
        rendered.append(indent + "#" + line[len(indent):])
        continue

    if active_deny.match(line) or commented_deny.match(line):
        if deny_interfaces and not deny_written:
            rendered.append(f"{deny_key}={deny_interfaces}")
            deny_written = True
        elif active_deny.match(line):
            rendered.append("#" + line)
        else:
            rendered.append(line)
        continue

    rendered.append(line)

if deny_interfaces and not deny_written:
    try:
        server_index = next(index for index, line in enumerate(rendered) if line.strip() == "[server]")
    except StopIteration as error:
        raise SystemExit("avahi config has no [server] section") from error
    rendered.insert(server_index + 1, f"{deny_key}={deny_interfaces}")

sys.stdout.write("\n".join(rendered).rstrip("\n") + "\n")
PY
}

m1s_render_avahi_alias_script() {
  cat <<'ALIASSCRIPT'
#!/usr/bin/env bash
set -eu
while true; do
  IFACE="$(ip route show default 2>/dev/null | awk '/default/ {print $5; exit}' || true)"
  if [[ -z "$IFACE" ]]; then
    sleep 5
    continue
  fi
  IP="$(ip -4 -o addr show dev "$IFACE" scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -n1)"
  if [[ -n "$IP" ]]; then
    exec avahi-publish-address -R umbrel.local "$IP"
  fi
  sleep 5
done
ALIASSCRIPT
}

m1s_render_avahi_alias_unit() {
  cat <<'SERVICEUNIT'
[Unit]
Description=Publish umbrel.local mDNS alias
After=avahi-daemon.service network-online.target
Requires=avahi-daemon.service
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/local/bin/avahi-publish-umbrel
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
SERVICEUNIT
}

m1s_collect_active_avahi_setting_values() {
  local config_file="${1:-$M1S_AVAHI_CONF}"
  local setting="$2"
  local output_mode="${3:-values}"

  python3 - "$config_file" "$setting" "$output_mode" <<'PY'
from pathlib import Path
import re
import sys

config_path = Path(sys.argv[1])
setting = sys.argv[2]
output_mode = sys.argv[3]
if setting not in {"allow-interfaces", "deny-interfaces"}:
    raise SystemExit(f"unsupported Avahi interface setting: {setting}")
if output_mode not in {"values", "interfaces"}:
    raise SystemExit(f"unsupported Avahi setting output mode: {output_mode}")
if output_mode == "interfaces" and setting != "deny-interfaces":
    raise SystemExit("interface output is supported only for deny-interfaces")
text = config_path.read_text(encoding="utf-8")
for value in re.findall(rf"(?m)^\s*{re.escape(setting)}\s*=\s*(.*?)\s*$", text):
    if output_mode == "values":
        print(value)
        continue
    for interface in value.split(","):
        interface = interface.strip()
        if interface:
            print(interface)
PY
}

m1s_collect_avahi_denied_interfaces() {
  local config_file="${1:-$M1S_AVAHI_CONF}"
  m1s_collect_active_avahi_setting_values "$config_file" deny-interfaces interfaces
}

m1s_validate_avahi_allow_interfaces() {
  local config_file="${1:-$M1S_AVAHI_CONF}"
  local -a active_allow=()

  [[ -f "$config_file" ]] || {
    printf 'Avahi config is missing: %s\n' "$config_file" >&2
    return 1
  }
  mapfile -t active_allow < <(m1s_collect_active_avahi_setting_values "$config_file" allow-interfaces)
  if [[ "${#active_allow[@]}" -gt 0 ]]; then
    printf 'active allow-interfaces remains\n' >&2
    return 1
  fi
}

m1s_validate_avahi_deny_interfaces() {
  local config_file="${1:-$M1S_AVAHI_CONF}"
  local expected_deny="${2:-$(m1s_collect_avahi_deny_interfaces)}"
  local -a active_deny=()

  [[ -f "$config_file" ]] || {
    printf 'Avahi config is missing: %s\n' "$config_file" >&2
    return 1
  }
  mapfile -t active_deny < <(m1s_collect_active_avahi_setting_values "$config_file" deny-interfaces)
  if [[ -n "$expected_deny" ]]; then
    [[ "${#active_deny[@]}" -eq 1 && "${active_deny[0]}" == "$expected_deny" ]] || {
      printf 'deny-interfaces mismatch: expected %s, got %s\n' "$expected_deny" "${active_deny[*]:-<absent>}" >&2
      return 1
    }
  elif [[ "${#active_deny[@]}" -gt 0 ]]; then
    printf 'deny-interfaces must be absent when no stable bridge exists: %s\n' "${active_deny[*]}" >&2
    return 1
  fi
}

m1s_avahi_interface_is_denied() {
  local config_file="${1:-$M1S_AVAHI_CONF}"
  local target_interface="$2"
  local denied_interface

  [[ -f "$config_file" && -n "$target_interface" ]] || return 1
  while IFS= read -r denied_interface; do
    [[ "$denied_interface" == "$target_interface" ]] && return 0
  done < <(m1s_collect_avahi_denied_interfaces "$config_file")
  return 1
}

m1s_validate_avahi_config_file() {
  local config_file="${1:-$M1S_AVAHI_CONF}"
  local expected_deny="${2:-$(m1s_collect_avahi_deny_interfaces)}"

  m1s_validate_avahi_allow_interfaces "$config_file" || return 1
  m1s_validate_avahi_deny_interfaces "$config_file" "$expected_deny"
}

m1s_install_rendered_file() {
  local target_file="$1"
  local mode="$2"
  local renderer="$3"
  local temp_file

  M1S_AVAHI_FILE_CHANGED=0
  temp_file="$(mktemp)" || return 1
  if ! "$renderer" > "$temp_file"; then
    rm -f "$temp_file"
    return 1
  fi
  if [[ -f "$target_file" ]] && cmp -s "$target_file" "$temp_file"; then
    rm -f "$temp_file"
    return 0
  fi

  M1S_AVAHI_FILE_CHANGED=1
  if ! run_cmd install -D -m "$mode" "$temp_file" "$target_file"; then
    rm -f "$temp_file"
    return 1
  fi
  rm -f "$temp_file"
}

m1s_write_avahi_config() {
  local config_file="${1:-$M1S_AVAHI_CONF}"
  local deny_interfaces="${2:-$(m1s_collect_avahi_deny_interfaces)}"
  local temp_file

  M1S_AVAHI_CONFIG_CHANGED=0
  if [[ ! -f "$config_file" ]]; then
    if [[ "${DRY_RUN:-0}" -eq 1 ]]; then
      printf '[DRY-RUN] render %s with deny-interfaces=%s after Avahi package installation\n' "$config_file" "${deny_interfaces:-<none>}"
      M1S_AVAHI_CONFIG_CHANGED=1
      return 0
    fi
    m1s_avahi_error "Avahi config is missing: $config_file"
    return 1
  fi

  temp_file="$(mktemp)" || return 1
  if ! m1s_render_avahi_config "$config_file" "$deny_interfaces" > "$temp_file"; then
    rm -f "$temp_file"
    m1s_avahi_error "Failed to render Avahi config: $config_file"
    return 1
  fi
  if cmp -s "$config_file" "$temp_file"; then
    rm -f "$temp_file"
    return 0
  fi

  if ! m1s_backup_file_with_retention "$config_file" '.bak' '+%s'; then
    rm -f "$temp_file"
    m1s_avahi_error "Failed to back up Avahi config: $config_file"
    return 1
  fi
  if ! run_cmd install -m 0644 "$temp_file" "$config_file"; then
    rm -f "$temp_file"
    m1s_avahi_error "Failed to write Avahi config: $config_file"
    return 1
  fi
  rm -f "$temp_file"

  if [[ "${DRY_RUN:-0}" -eq 0 ]] && ! m1s_validate_avahi_config_file "$config_file" "$deny_interfaces"; then
    m1s_avahi_error "Avahi config verification failed after writing: $config_file"
    return 1
  fi
  M1S_AVAHI_CONFIG_CHANGED=1
}

m1s_avahi_restart_recovery_hint() {
  local unit_name="$1"
  local fallback_ip
  fallback_ip="$(m1s_alias_publish_ipv4 || true)"
  m1s_avahi_error "$unit_name restart failed. Umbrel and Docker were not stopped or changed."
  m1s_avahi_error "Use http://${fallback_ip:-<device-ip>} until mDNS is repaired."
  m1s_avahi_error "Manual recovery command: sudo systemctl restart $unit_name"
}

m1s_configure_avahi_mdns() {
  local deny_interfaces alias_unit_name
  local alias_files_changed=0

  deny_interfaces="$(m1s_collect_avahi_deny_interfaces)"
  alias_unit_name="${M1S_AVAHI_ALIAS_SERVICE##*/}"

  if ! m1s_write_avahi_config "$M1S_AVAHI_CONF" "$deny_interfaces"; then
    return 1
  fi

  run_cmd systemctl enable --now avahi-daemon.service || return 1
  if [[ "$M1S_AVAHI_CONFIG_CHANGED" -eq 1 && "$M1S_AVAHI_RESTARTED" -eq 0 ]]; then
    if ! run_cmd systemctl restart avahi-daemon.service; then
      m1s_avahi_restart_recovery_hint avahi-daemon.service
      return 1
    fi
    M1S_AVAHI_RESTARTED=1
  fi

  if ! m1s_install_rendered_file "$M1S_AVAHI_ALIAS_SCRIPT" 0755 m1s_render_avahi_alias_script; then
    m1s_avahi_error "Failed to write Avahi alias script: $M1S_AVAHI_ALIAS_SCRIPT"
    return 1
  fi
  alias_files_changed=$((alias_files_changed + M1S_AVAHI_FILE_CHANGED))
  if ! m1s_install_rendered_file "$M1S_AVAHI_ALIAS_SERVICE" 0644 m1s_render_avahi_alias_unit; then
    m1s_avahi_error "Failed to write Avahi alias unit: $M1S_AVAHI_ALIAS_SERVICE"
    return 1
  fi
  alias_files_changed=$((alias_files_changed + M1S_AVAHI_FILE_CHANGED))

  run_cmd systemctl daemon-reload || return 1
  run_cmd systemctl enable "$alias_unit_name" || return 1
  if ! run_cmd systemctl restart "$alias_unit_name"; then
    m1s_avahi_restart_recovery_hint "$alias_unit_name"
    m1s_avahi_error "Failed to restart $alias_unit_name"
    return 1
  fi

  if [[ "$deny_interfaces" ]]; then
    m1s_avahi_info "Avahi excludes stable virtual bridges: $deny_interfaces"
  else
    m1s_avahi_info "No stable virtual bridges are currently present for Avahi exclusion."
  fi
  if [[ "$alias_files_changed" -gt 0 ]]; then
    m1s_avahi_info "Updated the umbrel.local alias script and unit."
  fi
}

m1s_avahi_internal_health_check() {
  local config_file="${1:-$M1S_AVAHI_CONF}"
  local default_iface default_ip publish_ip expected_deny
  local failed=0

  expected_deny="$(m1s_collect_avahi_deny_interfaces)"
  if ! m1s_validate_avahi_config_file "$config_file" "$expected_deny"; then
    m1s_avahi_error "mDNS configuration self-check failed: active allow-interfaces remains or deny-interfaces is stale."
    failed=1
  fi
  if ! command -v avahi-daemon >/dev/null 2>&1; then
    m1s_avahi_error "mDNS configuration self-check failed: avahi-daemon is not installed."
    failed=1
  elif ! systemctl is-enabled avahi-daemon.service >/dev/null 2>&1; then
    m1s_avahi_error "mDNS configuration self-check failed: avahi-daemon.service is not enabled."
    failed=1
  fi

  default_iface="$(m1s_default_route_interface || true)"
  default_ip="$(m1s_interface_ipv4 "$default_iface" || true)"
  if [[ -z "$default_iface" || -z "$default_ip" ]]; then
    m1s_avahi_error "mDNS configuration self-check failed: the default-route interface has no publishable IPv4 address."
    failed=1
  fi
  if [[ -n "$default_iface" ]] && m1s_avahi_interface_is_denied "$config_file" "$default_iface"; then
    m1s_avahi_error "mDNS configuration self-check failed: the default-route interface is denied by Avahi: $default_iface"
    failed=1
  fi
  publish_ip="$(m1s_alias_publish_ipv4 || true)"
  if [[ -z "$publish_ip" ]]; then
    m1s_avahi_error "mDNS configuration self-check failed: the umbrel.local alias cannot compute a publishable IPv4 address."
    failed=1
  fi

  [[ "$failed" -eq 0 ]]
}
