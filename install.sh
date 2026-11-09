#!/bin/bash
set -euo pipefail

# Установщик резервного копирования restic.
# Запуск: sudo ./install.sh [--force]
#   --force  перезаписать существующий /root/scripts/backup/.env

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_DIR="/root/scripts/backup"
SCANER_DIR="/root/scripts"
FORCE=0

for arg in "$@"; do
  case "$arg" in
    --force) FORCE=1 ;;
    -h|--help)
      echo "Использование: sudo $0 [--force]"
      exit 0
      ;;
    *)
      echo "Неизвестный аргумент: $arg" >&2
      exit 1
      ;;
  esac
done

log()  { printf '[install] %s\n' "$*"; }
die()  { printf '[install] ОШИБКА: %s\n' "$*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "запустите установщик через sudo"

# ---------------------------------------------------------------------------
# Конфигурация
# ---------------------------------------------------------------------------

ENV_SRC="$SCRIPT_DIR/.env"
if [ ! -f "$ENV_SRC" ]; then
  if [ -f "$SCRIPT_DIR/.env.example" ]; then
    cp "$SCRIPT_DIR/.env.example" "$SCRIPT_DIR/.env"
    die "создан $SCRIPT_DIR/.env. Заполните RESTIC_REPOSITORY и запустите установку снова"
  fi
  die "не найден $SCRIPT_DIR/.env"
fi

bash -n "$ENV_SRC" || die "синтаксическая ошибка в $ENV_SRC"

# shellcheck disable=SC1090
source "$ENV_SRC"

if [ -z "${RESTIC_REPOSITORY:-}" ] \
  || [[ "${RESTIC_REPOSITORY}" == *"CHANGE_ME"* ]] \
  || [[ "${RESTIC_REPOSITORY}" == *"restic.example.com"* ]] \
  || [[ "${RESTIC_REPOSITORY}" == *"LOGIN:PASSWORD"* ]]; then
  die "заполните NAME, RESTIC_HOST и RESTIC_HTTP_PASSWORD в $ENV_SRC"
fi

BACKUP_CRON="${BACKUP_CRON:-0 2 * * *}"

# ---------------------------------------------------------------------------
# Зависимости
# ---------------------------------------------------------------------------

install_dependencies() {
  local missing=() pm="" packages=()

  for cmd in curl bzip2 gzip crontab; do
    command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
  done

  if [ "${#missing[@]}" -eq 0 ]; then
    log "зависимости уже установлены"
    return
  fi

  if command -v apt-get >/dev/null 2>&1; then
    pm="apt-get"; packages=(curl bzip2 gzip cron)
  elif command -v dnf >/dev/null 2>&1; then
    pm="dnf"; packages=(curl bzip2 gzip cronie)
  elif command -v yum >/dev/null 2>&1; then
    pm="yum"; packages=(curl bzip2 gzip cronie)
  else
    die "не удалось определить пакетный менеджер. Установите вручную: ${missing[*]}"
  fi

  log "установка зависимостей: ${packages[*]}"
  if [ "$pm" = "apt-get" ]; then
    DEBIAN_FRONTEND=noninteractive apt-get update -qq
    DEBIAN_FRONTEND=noninteractive apt-get install -y "${packages[@]}"
  else
    "$pm" install -y "${packages[@]}"
  fi
}

# ---------------------------------------------------------------------------
# Restic
# ---------------------------------------------------------------------------

install_restic() {
  local arch version current tmp

  case "$(uname -m)" in
    x86_64|amd64)   arch="amd64" ;;
    aarch64|arm64)  arch="arm64" ;;
    armv7l|armhf)   arch="arm" ;;
    *) die "неподдерживаемая архитектура: $(uname -m)" ;;
  esac

  version="${RESTIC_VERSION:-}"
  if [ -z "$version" ]; then
    version="$(curl -fsSL --max-time 30 \
      https://api.github.com/repos/restic/restic/releases/latest \
      | grep -oP '"tag_name":\s*"v\K[^"]+' || true)"
  fi
  [ -n "$version" ] || die "не удалось определить последнюю версию restic (нет доступа к GitHub?)"
  version="${version#v}"

  if command -v restic >/dev/null 2>&1; then
    current="$(restic version 2>/dev/null | awk '{print $2}' | sed 's/^v//' || true)"
    if [ "$current" = "$version" ]; then
      log "restic $version уже установлен"
      return
    fi
    log "обновление restic: ${current:-неизвестно} -> $version"
  else
    log "установка restic $version"
  fi

  tmp="$(mktemp -d)"
  trap "rm -rf '$tmp'" EXIT

  curl -fsSL --max-time 300 -o "$tmp/restic.bz2" \
    "https://github.com/restic/restic/releases/download/v${version}/restic_${version}_linux_${arch}.bz2"
  bzip2 -d "$tmp/restic.bz2"
  chmod +x "$tmp/restic"

  if [ -f /usr/bin/restic ]; then
    cp -a /usr/bin/restic "/usr/bin/restic.backup.$(date +%Y%m%d_%H%M%S)"
  fi
  install -m 0755 "$tmp/restic" /usr/bin/restic

  log "установлен $(/usr/bin/restic version)"
}

# ---------------------------------------------------------------------------
# Скрипты
# ---------------------------------------------------------------------------

install_scripts() {
  install -d -m 0755 "$INSTALL_DIR" "$SCANER_DIR"

  install -m 0700 "$SCRIPT_DIR/backup.sh" "$INSTALL_DIR/backup.sh"
  install -m 0700 "$SCRIPT_DIR/main.sh"   "$INSTALL_DIR/main.sh"
  install -m 0755 "$SCRIPT_DIR/test_mail.sh" "$INSTALL_DIR/test_mail.sh"
  install -m 0755 "$SCRIPT_DIR/test_telegram.sh" "$INSTALL_DIR/test_telegram.sh"
  install -m 0755 "$SCRIPT_DIR/db_scaner.sh" "$SCANER_DIR/db_scaner.sh"

  if [ -f "$INSTALL_DIR/.env" ] && [ "$FORCE" -ne 1 ]; then
    log "существующий $INSTALL_DIR/.env сохранён (для перезаписи: --force)"
  else
    install -m 0600 "$ENV_SRC" "$INSTALL_DIR/.env"
    log "конфигурация записана в $INSTALL_DIR/.env"
  fi

  log "скрипты установлены в $INSTALL_DIR"
}

# ---------------------------------------------------------------------------
# Cron
# ---------------------------------------------------------------------------

setup_cron() {
  local line="$BACKUP_CRON $INSTALL_DIR/main.sh"
  local current new

  command -v crontab >/dev/null 2>&1 || die "команда crontab не найдена"

  current="$(mktemp)"
  new="$(mktemp)"
  crontab -l 2>/dev/null > "$current" || true

  # Удаляем прежние записи для этого main.sh, чтобы не плодить дубликаты
  grep -Fv "$INSTALL_DIR/main.sh" "$current" > "$new" || true
  printf '%s\n' "$line" >> "$new"
  crontab "$new"
  rm -f "$current" "$new"

  log "cron настроен: $line"

  if command -v systemctl >/dev/null 2>&1; then
    systemctl enable --now cron 2>/dev/null \
      || systemctl enable --now crond 2>/dev/null \
      || log "предупреждение: не удалось запустить службу cron"
  fi
}

# ---------------------------------------------------------------------------

install_dependencies
install_restic
install_scripts
setup_cron

cat <<EOF

Установка завершена.

  Скрипты:  $INSTALL_DIR
  Конфиг:   $INSTALL_DIR/.env
  Лог:      $INSTALL_DIR/backup.log
  Cron:     $BACKUP_CRON

Проверить вручную:
  sudo $INSTALL_DIR/main.sh

Проверить отправку почты:
  sudo $INSTALL_DIR/test_mail.sh

Проверить Telegram:
  sudo $INSTALL_DIR/test_telegram.sh

Посмотреть лог:
  sudo tail -f $INSTALL_DIR/backup.log
EOF
