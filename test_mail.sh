#!/bin/bash

# Проверка настройки почты: отправляет тестовое письмо.
# Запуск: ./test_mail.sh  (или sudo /root/scripts/backup/test_mail.sh после установки)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck disable=SC1091
source "$SCRIPT_DIR/backup.sh"

if [ -z "${MAIL_FROM:-}" ] || [ -z "${MAIL_RCPT:-}" ]; then
  echo "Ошибка: MAIL_FROM и MAIL_RCPT должны быть заполнены в $SCRIPT_DIR/.env" >&2
  exit 1
fi

if send_mail "Тест отправки почты: $NAME" \
  "Тестовое письмо от скрипта restic backup.

Сервер: $NAME
Дата:   $(date -R)

Если вы видите это письмо, отправка почты настроена."; then
  echo "Письмо отправлено на $MAIL_RCPT"
else
  echo "Не удалось отправить письмо. Проверьте SMTP_URL, логин, пароль и доступ к серверу." >&2
  exit 1
fi
