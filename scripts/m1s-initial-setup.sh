#!/usr/bin/env bash
set -Eeuo pipefail

# ODROID M1S Initial Setup
# Umbrel 설치 후 실행: 새 계정 생성 + 호스트 이름 변경 + (선택) 기존 계정 삭제
#
# 사용법:
#   sudo bash m1s-initial-setup.sh
#   sudo bash m1s-initial-setup.sh --dry-run

DRY_RUN=0
NEW_HOSTNAME="odroid"

log() {
  printf '[%s] %s\n' "$1" "$2"
}

info() { log INFO "$1"; }
warn() { log WARN "$1"; }
err() { log ERROR "$1" >&2; }

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

usage() {
  cat <<'EOF'
ODROID M1S Initial Setup — 새 사용자 계정 생성 + 호스트 이름 변경

Usage:
  sudo bash m1s-initial-setup.sh [options]

Options:
  --dry-run    Show actions without changing anything
  -h, --help   Show this help

이 스크립트는 Umbrel 설치 스크립트(m1s-clean-install-umbrel.sh) 실행 후에 사용합니다.

스크립트가 하는 일:
  1. 새 사용자 계정을 만들고 sudo/docker 권한을 부여합니다.
  2. 호스트 이름을 변경합니다 (기본값: odroid).
  3. 새 계정으로 재로그인 후, 기존 계정을 삭제하는 방법을 안내합니다.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)
      DRY_RUN=1
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      err "Unknown argument: $1"
      usage
      exit 1
      ;;
  esac
  shift
done

if [[ "${EUID}" -ne 0 ]]; then
  err "이 스크립트는 sudo 또는 root로 실행해야 합니다."
  err "예: sudo bash m1s-initial-setup.sh"
  exit 1
fi

CURRENT_USER="${SUDO_USER:-}"
if [[ -z "$CURRENT_USER" || "$CURRENT_USER" == "root" ]]; then
  err "sudo를 통해 실행해 주세요. (예: sudo bash m1s-initial-setup.sh)"
  err "root로 직접 로그인한 상태에서는 현재 사용자를 판별할 수 없습니다."
  exit 1
fi

CURRENT_HOSTNAME="$(hostname)"

echo
echo "=== ODROID M1S 초기 설정 ==="
echo "현재 사용자:   $CURRENT_USER"
echo "현재 호스트명: $CURRENT_HOSTNAME"
echo

# ─── 1. 새 사용자 이름 입력 ───

while true; do
  read -r -p "새 사용자 이름을 입력하세요: " NEW_USER

  if [[ -z "$NEW_USER" ]]; then
    warn "사용자 이름을 입력해 주세요."
    continue
  fi

  # 유효한 리눅스 사용자 이름인지 확인 (소문자, 숫자, 하이픈, 언더스코어)
  if [[ ! "$NEW_USER" =~ ^[a-z_][a-z0-9_-]*$ ]]; then
    warn "사용자 이름은 영문 소문자, 숫자, 하이픈(-), 언더스코어(_)만 사용할 수 있습니다."
    warn "첫 글자는 소문자 또는 언더스코어여야 합니다."
    continue
  fi

  if [[ ${#NEW_USER} -gt 32 ]]; then
    warn "사용자 이름은 32자 이하여야 합니다."
    continue
  fi

  if [[ "$NEW_USER" == "$CURRENT_USER" ]]; then
    warn "'$NEW_USER'는 현재 사용 중인 계정과 같습니다. 다른 이름을 입력해 주세요."
    continue
  fi

  if id "$NEW_USER" >/dev/null 2>&1; then
    warn "'$NEW_USER' 계정이 이미 존재합니다. 다른 이름을 입력해 주세요."
    continue
  fi

  break
done

# ─── 2. 비밀번호 입력 ───

while true; do
  read -r -s -p "새 비밀번호: " NEW_PASS
  echo

  if [[ -z "$NEW_PASS" ]]; then
    warn "비밀번호를 입력해 주세요."
    continue
  fi

  if [[ ${#NEW_PASS} -lt 4 ]]; then
    warn "비밀번호는 최소 4자 이상이어야 합니다."
    continue
  fi

  read -r -s -p "비밀번호 확인: " NEW_PASS_CONFIRM
  echo

  if [[ "$NEW_PASS" != "$NEW_PASS_CONFIRM" ]]; then
    warn "비밀번호가 일치하지 않습니다. 다시 입력해 주세요."
    continue
  fi

  break
done

# ─── 3. 호스트 이름 입력 ───

echo
read -r -p "새 호스트 이름 [odroid]: " INPUT_HOSTNAME
if [[ -n "$INPUT_HOSTNAME" ]]; then
  NEW_HOSTNAME="$INPUT_HOSTNAME"
fi

# 유효한 호스트 이름인지 확인
if [[ ! "$NEW_HOSTNAME" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?$ ]]; then
  err "호스트 이름은 영문, 숫자, 하이픈(-)만 사용할 수 있고, 하이픈으로 시작/끝날 수 없습니다."
  exit 1
fi

if [[ ${#NEW_HOSTNAME} -gt 63 ]]; then
  err "호스트 이름은 63자 이하여야 합니다."
  exit 1
fi

# ─── 4. 요약 및 확인 ───

echo
echo "=== 변경 요약 ==="
echo "새 사용자:     $NEW_USER"
echo "새 호스트명:   $NEW_HOSTNAME"
echo "현재 사용자:   $CURRENT_USER (지금은 삭제하지 않습니다)"
echo

if [[ "$DRY_RUN" -eq 1 ]]; then
  echo "[DRY-RUN 모드] 실제 변경은 수행하지 않습니다."
  echo
fi

read -r -p "진행하시겠습니까? [y/N]: " CONFIRM
if [[ "$CONFIRM" != "y" && "$CONFIRM" != "Y" ]]; then
  echo "취소되었습니다."
  exit 0
fi

echo

# ─── 5. 새 사용자 생성 ───

info "새 사용자 '$NEW_USER' 생성 중..."
run_cmd useradd -m -s /bin/bash "$NEW_USER"

info "비밀번호 설정 중..."
if [[ "$DRY_RUN" -eq 1 ]]; then
  echo "[DRY-RUN] chpasswd (password hidden)"
else
  printf '%s:%s\n' "$NEW_USER" "$NEW_PASS" | chpasswd
fi

info "sudo 그룹에 추가 중..."
run_cmd usermod -aG sudo "$NEW_USER"

if getent group docker >/dev/null 2>&1; then
  info "docker 그룹에 추가 중..."
  run_cmd usermod -aG docker "$NEW_USER"
fi

# ─── 6. 호스트 이름 변경 ───

if [[ "$NEW_HOSTNAME" != "$CURRENT_HOSTNAME" ]]; then
  info "호스트 이름을 '$NEW_HOSTNAME'(으)로 변경 중..."
  run_cmd hostnamectl set-hostname "$NEW_HOSTNAME"

  # /etc/hosts 업데이트
  if [[ "$DRY_RUN" -eq 1 ]]; then
    echo "[DRY-RUN] /etc/hosts: '$CURRENT_HOSTNAME' → '$NEW_HOSTNAME'"
  else
    if grep -q "$CURRENT_HOSTNAME" /etc/hosts; then
      sed -i "s/$CURRENT_HOSTNAME/$NEW_HOSTNAME/g" /etc/hosts
    fi
    # 127.0.1.1 엔트리가 없으면 추가
    if ! grep -q "127.0.1.1" /etc/hosts; then
      printf '127.0.1.1\t%s\n' "$NEW_HOSTNAME" >> /etc/hosts
    fi
  fi
else
  info "호스트 이름이 이미 '$NEW_HOSTNAME'입니다. 변경하지 않습니다."
fi

# ─── 7. 완료 안내 ───

echo
echo "========================================="
echo "  초기 설정 완료!"
echo "========================================="
echo
echo "새 계정 '$NEW_USER'가 생성되었습니다."
echo "호스트 이름: $NEW_HOSTNAME"
echo
echo "다음 단계:"
echo "  1. 지금 로그아웃하세요: exit"
echo "  2. 새 계정으로 로그인하세요: $NEW_USER"
echo "  3. 기존 계정 '$CURRENT_USER'를 삭제하려면 다음을 실행하세요:"
echo
echo "     sudo userdel -r $CURRENT_USER"
echo
echo "  주의: 기존 계정의 홈 디렉터리(/home/$CURRENT_USER)도 함께 삭제됩니다."
echo "  필요한 파일이 있다면 삭제 전에 미리 복사해 두세요."
echo
if [[ "$DRY_RUN" -eq 1 ]]; then
  echo "[DRY-RUN] 위 내용은 모두 시뮬레이션입니다. 실제 변경은 없었습니다."
fi
