#!/bin/bash

# Точка входа резервного копирования.
# Запускается по cron. Настройки и списки БД берутся из .env рядом со скриптом.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG="$SCRIPT_DIR/backup.log"

# shellcheck disable=SC1091
source "$SCRIPT_DIR/backup.sh"

echo "=== $(date) ===" > "$LOG"

# Останавливает весь сценарий, если подготовка данных (дамп БД) завершилась ошибкой.
# В этом случае restic backup не запускается.
abort_on_failure() {
  local what="$1"
  echo "** Бэкап прерван: ошибка — $what. Restic backup не запускался." >> "$LOG"
  exit 1
}

# --- PostgreSQL ---
if [ "${#POSTGRES_BACKUPS[@]}" -gt 0 ]; then
  echo "** Бэкап БД" >> "$LOG"
  for entry in "${POSTGRES_BACKUPS[@]}"; do
    IFS='|' read -r db user <<< "$entry"
    backup_db_postgres "$db" "$user" \
      || abort_on_failure "PostgreSQL: $db"
  done
fi

# --- MySQL/MariaDB ---
if [ "${#MYSQL_BACKUPS[@]}" -gt 0 ]; then
  echo "** Бэкап БД" >> "$LOG"
  for entry in "${MYSQL_BACKUPS[@]}"; do
    IFS='|' read -r db user <<< "$entry"
    backup_db_mysql "$db" "$user" \
      || abort_on_failure "MySQL: $db"
  done
fi

# --- PostgreSQL в Docker ---
if [ "${#POSTGRES_DOCKER_BACKUPS[@]}" -gt 0 ]; then
  echo "** Бэкап БД" >> "$LOG"
  for entry in "${POSTGRES_DOCKER_BACKUPS[@]}"; do
    IFS='|' read -r db user container <<< "$entry"
    backup_db_postgres_docker "$db" "$user" "$container" \
      || abort_on_failure "PostgreSQL (docker: $container): $db"
  done
fi

# --- MongoDB в Docker ---
if [ "${#MONGO_DOCKER_BACKUPS[@]}" -gt 0 ]; then
  echo "** Бэкап БД" >> "$LOG"
  for entry in "${MONGO_DOCKER_BACKUPS[@]}"; do
    IFS='|' read -r db user pass container <<< "$entry"
    backup_db_mongo_docker "$db" "$user" "$pass" "$container" \
      || abort_on_failure "MongoDB (docker: $container): $db"
  done
fi

# --- GitLab ---
if [ "${GITLAB_BACKUP:-no}" = "yes" ]; then
  echo '** GitLab backup' >> "$LOG"
  gitlab_backup
fi

# --- Проверка целостности репозитория ---
if [ "${RESTIC_CHECK:-no}" = "yes" ]; then
  echo '** Restic check' >> "$LOG"
  restic_check
fi

# --- Основной бэкап ---
echo '** Restic backup' >> "$LOG"
restic_backup
