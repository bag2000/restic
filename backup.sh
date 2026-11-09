#!/bin/bash

# Библиотека функций резервного копирования.
# Подключается из main.sh. Все настройки берутся из .env рядом со скриптом.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG="${LOG:-$SCRIPT_DIR/backup.log}"

if [ ! -f "$SCRIPT_DIR/.env" ]; then
  echo "Ошибка: не найден файл конфигурации $SCRIPT_DIR/.env" >&2
  echo "Скопируйте .env.example в .env и заполните его." >&2
  exit 1
fi

# shellcheck disable=SC1091
source "$SCRIPT_DIR/.env"

NAME="${NAME:-$(hostname)}"

# Аргументы аутентификации restic.
# Если RESTIC_PASSWORD задан, используем его, иначе репозиторий без пароля.
RESTIC_AUTH_ARGS=()
if [ -n "${RESTIC_PASSWORD:-}" ]; then
  export RESTIC_PASSWORD
else
  RESTIC_AUTH_ARGS+=("--insecure-no-password")
fi

export BACKUP_PATH BACKUP_EXCLUDE RESTIC_REPOSITORY CPU_LIMIT MEM_LIMIT

# Отправка письма.
# Аргументы: $1 - тема, $2 - текст
send_mail() {
  local subject="$1"
  local body="$2"

  if [ -z "${MAIL_FROM:-}" ] || [ -z "${MAIL_RCPT:-}" ]; then
    return 0
  fi

  local url="${SMTP_URL:-smtp://localhost:25}"
  local -a curl_args=(--url "$url" --mail-from "$MAIL_FROM" --upload-file - -sS --max-time 30)
  local -a recipients=()
  local rcpt

  # Получатели могут быть перечислены через запятую или пробел
  read -r -a recipients <<< "${MAIL_RCPT//,/ }"
  for rcpt in "${recipients[@]}"; do
    [ -n "$rcpt" ] && curl_args+=(--mail-rcpt "$rcpt")
  done
  [ "${#recipients[@]}" -gt 0 ] || return 0

  # smtp://  — подключение + STARTTLS (обычно порт 587)
  # smtps:// — TLS сразу (обычно порт 465)
  case "$url" in
    smtp://*)
      [ "${SMTP_STARTTLS:-yes}" = "no" ] || curl_args+=(--ssl-reqd)
      ;;
  esac

  if [ -n "${MAIL_FROM_PASSWORD:-}" ]; then
    curl_args+=(--user "${SMTP_USER:-$MAIL_FROM}:${MAIL_FROM_PASSWORD}")
    # Некоторые серверы предлагают GSSAPI/NTLM, которые curl выбирает первыми
    # и не может пройти без Kerberos. SMTP_AUTH=LOGIN заставляет использовать LOGIN.
    if [ -n "${SMTP_AUTH:-}" ]; then
      curl_args+=(--login-options "AUTH=$SMTP_AUTH")
    fi
  fi

  # Тема в UTF-8 по RFC 2047
  local subject_b64
  subject_b64="$(printf '%s' "$subject" | base64 | tr -d '\n')"

  local curl_rc=0
  printf 'From: %s\nTo: %s\nSubject: =?UTF-8?B?%s?=\nDate: %s\nContent-Type: text/plain; charset=utf-8\nContent-Transfer-Encoding: 8bit\n\n%s\n' \
    "$MAIL_FROM" "$MAIL_RCPT" "$subject_b64" "$(date -R)" "$body" \
    | curl "${curl_args[@]}" || curl_rc=$?

  if [ "$curl_rc" -ne 0 ]; then
    echo "** Ошибка отправки письма на $MAIL_RCPT (curl rc=$curl_rc)" >> "$LOG"
    if [ "$curl_rc" -eq 94 ]; then
      echo "** Подсказка: сервер не принял выбранный механизм авторизации. Попробуйте SMTP_AUTH=LOGIN" >> "$LOG"
    fi
    return 1
  fi

  echo "** Письмо отправлено на $MAIL_RCPT" >> "$LOG"
  return 0
}

# Отправка сообщения в Telegram.
# Аргументы: $1 - текст сообщения
send_telegram() {
  local message="$1"

  if [ -z "${TG_TOKEN:-}" ] || [ -z "${TG_CHAT_ID:-}" ]; then
    return 0
  fi

  local proxy_args=()
  if [ -n "${PROXY:-}" ]; then
    proxy_args=(-x "$PROXY")
  fi

  if ! curl "${proxy_args[@]}" -sS --max-time 15 -X POST \
      "https://api.telegram.org/bot${TG_TOKEN}/sendMessage" \
      -d chat_id="$TG_CHAT_ID" -d text="$message" >/dev/null; then
    echo "** Ошибка отправки сообщения в Telegram" >> "$LOG"
    return 1
  fi

  echo "** Сообщение отправлено в Telegram" >> "$LOG"
  return 0
}

# Отправка сообщения об ошибке в Telegram и на почту.
# Аргументы: $1 - текст сообщения
send_alert() {
  local message="$1"

  send_telegram "$message" || true
  send_mail "${MAIL_SUBJECT_PREFIX:-Restic backup}: $NAME" "$message" || true
}

# Бэкап БД Postgres
# Аргументы: $1 - имя БД (или "all"), $2 - пользователь
backup_db_postgres() {
  local BASE=$1                                 # Имя базы или "all" для всех БД
  local USER=$2                                 # Пользователь БД
  local DUMP_PATH="${DB_DUMP_PATH:-/bak/db}"    # Директория для хранения бэкапов
  local OUT_FILE="$DUMP_PATH/dump_${BASE}.gz"   # Результирующий файл

  # Создаем директорию для хранения бэкапов
  mkdir -p "$DUMP_PATH"; cd /tmp || return 1

  # Выбор метода: дамп всех баз или одной конкретной
  # Направляем поток ошибок (stderr) обеих команд в лог $LOG
  if [ "$BASE" = "all" ]; then
    sudo -u "$USER" pg_dumpall 2>>"$LOG" | gzip 2>>"$LOG" > "$OUT_FILE"
  else
    sudo -u "$USER" pg_dump "$BASE" 2>>"$LOG" | gzip 2>>"$LOG" > "$OUT_FILE"
  fi

  # Сохранение кодов возврата всего конвейера (pipe) в STATUSES
  local STATUSES=("${PIPESTATUS[@]}")

  # Проверка статуса: [0] — pg_dump, [1] — gzip
  if [ "${STATUSES[0]}" -ne 0 ] || [ "${STATUSES[1]}" -ne 0 ]; then
    echo "** Ошибка дампа или сжатия БД $BASE" >> "$LOG"

    # Удаляем битый файл, так как gzip создает его даже при пустом входе
    rm -f "$OUT_FILE"

    send_alert "❌ Ошибка БД $BASE $NAME (Коды: ${STATUSES[*]})"

    return 1
  fi

  echo "** Успех дампа БД $BASE" >> "$LOG"
  cd "$SCRIPT_DIR" || return 1
}

# Бэкап БД MongoDB в Docker контейнере
# Аргументы: $1 - имя БД (или "all"), $2 - пользователь, $3 - пароль, $4 - имя контейнера
backup_db_mongo_docker() {
  local BASE=$1                                 # Имя базы или "all" для всех БД
  local USER=$2                                 # Пользователь БД
  local PASS=$3                                 # Пароль БД
  local CONTAINER=$4                            # Имя Docker-контейнера
  local DUMP_PATH="${DB_DUMP_PATH:-/bak/db}"    # Директория для хранения бэкапов
  local OUT_FILE="$DUMP_PATH/dump_${CONTAINER}_${BASE}.dump"

  # Создаем директорию для хранения бэкапов
  mkdir -p "$DUMP_PATH"

  # Выбор метода: дамп всех баз или одной конкретной
  if [ "$BASE" = "all" ]; then
    sudo docker exec -i "$CONTAINER" mongodump --archive \
      --uri="mongodb://$USER:$PASS@localhost:27017/?authSource=admin" \
      2>>"$LOG" > "$OUT_FILE"
  else
    sudo docker exec -i "$CONTAINER" mongodump --archive \
      --db "$BASE" \
      --uri="mongodb://$USER:$PASS@localhost:27017/?authSource=admin" \
      2>>"$LOG" > "$OUT_FILE"
  fi

  # Проверка статуса
  if [ $? -ne 0 ]; then
    echo "** Ошибка дампа БД $BASE" >> "$LOG"
    rm -f "$OUT_FILE"
    send_alert "❌ Ошибка дампа MongoDB БД $BASE $NAME"
    return 1
  fi

  echo "** Успех дампа БД $BASE" >> "$LOG"
}

# Бэкап БД Postgres в Docker контейнере
# Аргументы: $1 - имя БД (или "all"), $2 - пользователь, $3 - имя контейнера
backup_db_postgres_docker() {
  local BASE=$1                                 # Имя базы или "all" для всех БД
  local USER=$2                                 # Пользователь БД
  local CONTAINER=$3                            # Имя Docker-контейнера
  local DUMP_PATH="${DB_DUMP_PATH:-/bak/db}"    # Директория для хранения бэкапов
  local OUT_FILE="$DUMP_PATH/dump_${CONTAINER}_${BASE}.gz"

  # Создаем директорию для хранения бэкапов
  mkdir -p "$DUMP_PATH"

  # Выбор метода: дамп всех баз или одной конкретной
  # Направляем поток ошибок (stderr) обеих команд в лог $LOG
  if [ "$BASE" = "all" ]; then
    sudo docker exec "$CONTAINER" pg_dumpall -U "$USER" 2>>"$LOG" | gzip 2>>"$LOG" > "$OUT_FILE"
  else
    sudo docker exec "$CONTAINER" pg_dump -U "$USER" "$BASE" 2>>"$LOG" | gzip 2>>"$LOG" > "$OUT_FILE"
  fi

  # Сохранение кодов возврата всего конвейера (pipe) в STATUSES
  local STATUSES=("${PIPESTATUS[@]}")

  # Проверка статуса: [0] — docker/pg_dump, [1] — gzip
  if [ "${STATUSES[0]}" -ne 0 ] || [ "${STATUSES[1]}" -ne 0 ]; then
    echo "** Ошибка дампа или сжатия БД $BASE" >> "$LOG"

    # Удаляем битый файл, так как gzip создает его даже при пустом входе
    rm -f "$OUT_FILE"

    send_alert "❌ Ошибка БД $BASE $NAME (Коды: ${STATUSES[*]})"

    return 1
  fi

  echo "** Успех дампа БД $BASE" >> "$LOG"
}

# Бэкап БД MySQL/MariaDB
# Аргументы: $1 - имя БД (или "all"), $2 - пользователь
backup_db_mysql() {
  local BASE=$1                                 # Имя базы или "all" для всех БД
  local USER=$2                                 # Пользователь БД
  local DUMP_PATH="${DB_DUMP_PATH:-/bak/db}"    # Директория для хранения бэкапов
  local OUT_FILE="$DUMP_PATH/dump_${BASE}.gz"   # Результирующий файл

  # Создаем директорию для хранения бэкапов
  mkdir -p "$DUMP_PATH"; cd /tmp || return 1

  # Выбор метода: дамп всех баз или одной конкретной
  # Направляем поток ошибок (stderr) обеих команд в лог $LOG
  if [ "$BASE" = "all" ]; then
    sudo mysqldump -u "$USER" --all-databases --log-error="$LOG" | gzip 2>>"$LOG" > "$OUT_FILE"
  else
    sudo mysqldump -u "$USER" --log-error="$LOG" "$BASE" | gzip 2>>"$LOG" > "$OUT_FILE"
  fi

  # Сохранение кодов возврата всего конвейера (pipe) в STATUSES
  local STATUSES=("${PIPESTATUS[@]}")

  # Проверка статуса: [0] — mysqldump, [1] — gzip
  if [ "${STATUSES[0]}" -ne 0 ] || [ "${STATUSES[1]}" -ne 0 ]; then
    echo "** Ошибка дампа или сжатия БД $BASE" >> "$LOG"

    # Удаляем битый файл, так как gzip создает его даже при пустом входе
    rm -f "$OUT_FILE"

    send_alert "❌ Ошибка БД $BASE $NAME (Коды: ${STATUSES[*]})"

    return 1
  fi

  echo "** Успех дампа БД $BASE" >> "$LOG"
  cd "$SCRIPT_DIR" || return 1
}

# Резервное копирование GitLab своими средствами.
gitlab_backup() {
  local BACKUP_DIR="${GITLAB_BACKUP_DIR:-/bak/gitlab}"

  # Чистим старые бэкапы
  rm -f "$BACKUP_DIR"/*ee_gitlab_backup.tar

  # Запускаем gitlab-backup
  /opt/gitlab/bin/gitlab-backup create CRON=1 SKIP=artifacts 2>&1 | tee -a "$LOG"

  # Сохранение кодов возврата всего конвейера (pipe) в STATUSES
  local STATUSES=("${PIPESTATUS[@]}")

  # Проверка статуса: [0] — gitlab backup
  if [ "${STATUSES[0]}" -ne 0 ]; then
    echo "** Ошибка gitlab backup" >> "$LOG"
    send_alert "❌ Ошибка gitlab backup $NAME"
    exit 1
  fi
}

# Проверка restic check.
# Делает в зависимости от даты день/28. Если 29, 30 или 31 — пропускает проверку.
restic_check() {
  # Определяем текущее число (дата)
  local day
  day=$(date +%d | sed 's/^0//')

  # Если текущее число не 29, 30 и 31
  if [ "$day" -le 28 ]; then
    # Чистим кэш и разблокируем с проверкой ошибок
    restic "${RESTIC_AUTH_ARGS[@]}" cache --cleanup || echo "Предупреждение: ошибка очистки кэша" | tee -a "$LOG"
    restic "${RESTIC_AUTH_ARGS[@]}" unlock || echo "Предупреждение: ошибка разблокировки" | tee -a "$LOG"

    # Запускаем restic check
    restic "${RESTIC_AUTH_ARGS[@]}" check --read-data-subset "${day}/28" 2>&1 | tee -a "$LOG"
    local STATUSES=("${PIPESTATUS[@]}")

    if [ "${STATUSES[0]}" -ne 0 ]; then
      echo "** Ошибка check $NAME" | tee -a "$LOG"
      send_alert "❌ Ошибка check $NAME"
    fi
  fi
}

# Бэкап корневого раздела, исключает монтированные разделы и кэш файлы
restic_backup() {
  # Проверка на пустой RESTIC_REPOSITORY
  if [ -z "${RESTIC_REPOSITORY:-}" ]; then
    echo "Ошибка: RESTIC_REPOSITORY не задан. Проверьте .env" | tee -a "$LOG"
    exit 1
  fi

  # Проверки
  if [ ${#RESTIC_ARGS[@]} -eq 0 ]; then
    echo "Ошибка: RESTIC_ARGS не определен. Проверьте .env" | tee -a "$LOG"
    exit 1
  fi

  # Проверка на пустой BACKUP_PATH
  if [ -z "${BACKUP_PATH:-}" ]; then
    echo "Ошибка: BACKUP_PATH не задан" | tee -a "$LOG"
    exit 1
  fi

  # Чистим кэш и разблокируем с проверкой ошибок
  restic "${RESTIC_AUTH_ARGS[@]}" cache --cleanup || echo "Предупреждение: ошибка очистки кэша" | tee -a "$LOG"
  restic "${RESTIC_AUTH_ARGS[@]}" unlock || echo "Предупреждение: ошибка разблокировки" | tee -a "$LOG"

  # СОЗДАЕМ ЛОКАЛЬНЫЙ МАССИВ, чтобы не менять оригинал
  local cmd_args=("${RESTIC_ARGS[@]}")

  # Добавляем исключения
  if [ -n "${BACKUP_EXCLUDE:-}" ]; then
    local exclude_pattern
    for exclude_pattern in $BACKUP_EXCLUDE; do
      cmd_args+=(--exclude "$exclude_pattern")
    done
  fi

  # Добавляем путь
  cmd_args+=("$BACKUP_PATH")

  # Запускаем backup
  restic "${RESTIC_AUTH_ARGS[@]}" backup "${cmd_args[@]}" 2>&1 | tee -a "$LOG"
  local STATUSES=("${PIPESTATUS[@]}")

  if [ "${STATUSES[0]}" -ne 0 ]; then
    echo "** Ошибка бэкапа ${BACKUP_PATH}" | tee -a "$LOG"
    send_alert "❌ Ошибка бэкапа ${BACKUP_PATH} $NAME"
  fi
}
