#!/bin/sh
# =====================================================
# НАЗВАНИЕ: OpenWrt Dumb AP Launcher (macOS/Linux)
# ОПИСАНИЕ: Копирует f5go-openwrt-dumb-ap.sh на роутер OpenWrt по SCP
#           и запускает его через SSH. Без Python и сторонних зависимостей.
#           Если локального скрипта нет, пытается скачать его с GitHub.
# =====================================================

set -eu

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
LOCAL_SCRIPT="${SCRIPT_DIR}/f5go-openwrt-dumb-ap.sh"
REMOTE_SCRIPT="/tmp/f5go-openwrt-dumb-ap.sh"
DEFAULT_SCRIPT_URL="https://raw.githubusercontent.com/F5GO/F5GO-OpenWrt-Dumb-AP-Configurator/main/f5go-openwrt-dumb-ap.sh"

need_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "ERROR: не найдена команда '$1'." >&2
    exit 1
  fi
}

ask_with_default() {
  prompt="$1"
  default="$2"
  printf "%s [%s]: " "$prompt" "$default" >&2
  read -r value
  [ -z "$value" ] && value="$default"
  printf "%s" "$value"
}

download_script_if_missing() {
  if [ -f "$LOCAL_SCRIPT" ]; then
    return 0
  fi

  SCRIPT_URL="${F5GO_SCRIPT_URL:-$DEFAULT_SCRIPT_URL}"
  echo "Локальный файл не найден: $LOCAL_SCRIPT"
  echo "Пробую скачать: $SCRIPT_URL"

  if command -v curl >/dev/null 2>&1; then
    curl -fsSL "$SCRIPT_URL" -o "$LOCAL_SCRIPT" || {
      echo "ERROR: не удалось скачать скрипт через curl." >&2
      return 1
    }
  elif command -v wget >/dev/null 2>&1; then
    wget -qO "$LOCAL_SCRIPT" "$SCRIPT_URL" || {
      echo "ERROR: не удалось скачать скрипт через wget." >&2
      return 1
    }
  else
    echo "ERROR: нет curl/wget для скачивания скрипта." >&2
    return 1
  fi

  if [ ! -s "$LOCAL_SCRIPT" ]; then
    echo "ERROR: скачанный файл пустой: $LOCAL_SCRIPT" >&2
    return 1
  fi

  echo "Скрипт успешно скачан: $LOCAL_SCRIPT"
}

need_cmd ssh
need_cmd scp

if ! download_script_if_missing; then
  echo "Подсказка: скачай все файлы репозитория заранее (например, из GitHub Release)." >&2
  exit 1
fi

ROUTER_IP="$(ask_with_default "Router IP" "192.168.1.1")"
SSH_USER="$(ask_with_default "SSH user" "root")"
SSH_PORT="$(ask_with_default "SSH port" "22")"

TARGET="${SSH_USER}@${ROUTER_IP}:${REMOTE_SCRIPT}"

echo "Загрузка: $LOCAL_SCRIPT -> $TARGET"
scp -P "$SSH_PORT" "$LOCAL_SCRIPT" "$TARGET"
echo "Загрузка завершена."

echo "Запуск скрипта на роутере..."
ssh -tt -p "$SSH_PORT" "${SSH_USER}@${ROUTER_IP}" "chmod +x '$REMOTE_SCRIPT' && sh '$REMOTE_SCRIPT'"
echo "Готово."
