#!/usr/bin/env bash

M1S_SUPPORTED_OS_ID='ubuntu'
M1S_SUPPORTED_UBUNTU_VERSION='22.04'
M1S_SUPPORTED_KERNEL_SERIES='5.10'
M1S_SUPPORTED_MODEL='Hardkernel ODROID-M1S'
M1S_SUPPORTED_HOST_VERIFIED=0

m1s_supported_host_is_verified() {
  [[ "${M1S_SUPPORTED_HOST_VERIFIED:-0}" -eq 1 ]]
}

m1s_validate_supported_host_values() {
  local os_id="$1"
  local os_version="$2"
  local kernel_release="$3"
  local architecture="$4"
  local model="$5"

  [[ "$os_id" == "$M1S_SUPPORTED_OS_ID" ]] || return 1
  [[ "$os_version" == "$M1S_SUPPORTED_UBUNTU_VERSION" ]] || return 1
  [[ "$kernel_release" =~ ^5\.10\.[0-9]+([.-].*)?$ ]] || return 1
  [[ "$architecture" == 'aarch64' || "$architecture" == 'arm64' ]] || return 1
  [[ "$model" == "$M1S_SUPPORTED_MODEL" ]] || return 1
}

m1s_os_release_value() {
  local os_release_file="$1"
  local requested_key="$2"
  local line value=''
  local matches=0

  [[ -f "$os_release_file" && -r "$os_release_file" ]] || return 1

  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ "$line" == "$requested_key="* ]] || continue
    matches=$((matches + 1))
    value="${line#*=}"
    case "$value" in
      \"*)
        [[ "${#value}" -ge 2 && "$value" == *\" ]] || return 1
        value="${value#\"}"
        value="${value%\"}"
        ;;
      \')
        return 1
        ;;
      \'*)
        [[ "${#value}" -ge 2 && "$value" == *\' ]] || return 1
        value="${value#\'}"
        value="${value%\'}"
        ;;
    esac
  done < "$os_release_file"

  [[ "$matches" -eq 1 && -n "$value" ]] || return 1
  printf '%s' "$value"
}

m1s_print_unsupported_host_warning() {
  printf '[WARN] Host is outside the validated profile; continuing without blocking.\n' >&2
  printf '[WARN] Validated profile: ODROID M1S / Ubuntu %s Server / Linux %s.x (arm64).\n' \
    "$M1S_SUPPORTED_UBUNTU_VERSION" "$M1S_SUPPORTED_KERNEL_SERIES" >&2
}

m1s_host_os_id() {
  m1s_os_release_value /etc/os-release ID
}

m1s_host_os_version() {
  m1s_os_release_value /etc/os-release VERSION_ID
}

m1s_host_kernel_release() {
  uname -r
}

m1s_host_architecture() {
  uname -m
}

m1s_host_model() {
  if [[ -r /proc/device-tree/model ]]; then
    tr -d '\0' < /proc/device-tree/model
  elif [[ -r /sys/firmware/devicetree/base/model ]]; then
    tr -d '\0' < /sys/firmware/devicetree/base/model
  else
    return 1
  fi
}

m1s_report_host_support() {
  local os_id os_version kernel_release architecture model

  M1S_SUPPORTED_HOST_VERIFIED=0
  os_id="$(m1s_host_os_id 2>/dev/null || true)"
  os_version="$(m1s_host_os_version 2>/dev/null || true)"
  kernel_release="$(m1s_host_kernel_release 2>/dev/null || true)"
  architecture="$(m1s_host_architecture 2>/dev/null || true)"
  model="$(m1s_host_model 2>/dev/null || true)"

  if ! m1s_validate_supported_host_values "$os_id" "$os_version" "$kernel_release" "$architecture" "$model"; then
    m1s_print_unsupported_host_warning
    return 0
  fi

  M1S_SUPPORTED_HOST_VERIFIED=1
  return 0
}
