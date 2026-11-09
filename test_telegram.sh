#!/bin/bash

# Проверка настройки Telegram: отправляет тестовое сообщение.
# Запуск: ./test_telegram.sh  (или sudo /root/scripts/backup/test_telegram.sh)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck disable=SC1091
source "$SCRIPT_DIR/backup.sh"

if [ -z "${TG_TOKEN:-}" ] || [ -z "${TG_CHAT_ID:-}" ]; then
  echo "Ошибка: TG_TOKEN и TG_CHAT_ID должны быть заполнены в $SCRIPT_DIR/.env" >&2
  exit 1
fi

if send_telegram "Тест уведомлений restic backup: $NAME

Сервер: $NAME
Дата:   $(date -R)"; then
  echo "Сообщение отправлено в Telegram (chat_id $TG_CHAT_ID)"
else
  echo "Не удалось отправить сообщение. Проверьте TG_TOKEN, TG_CHAT_ID и PROXY." >&2
  exit 1
fi
