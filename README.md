# Restic backup

Standalone-набор скриптов для резервного копирования сервера через [restic](https://restic.net/).
Ansible не используется: всё настраивается через `.env` и установщик `install.sh`.

## Состав

| Файл | Назначение |
|------|------------|
| `install.sh` | Устанавливает restic, раскладывает скрипты в `/root/scripts/backup`, настраивает cron |
| `.env.example` | Шаблон конфигурации. Копируется в `.env` и заполняется |
| `main.sh` | Точка входа: дампы БД, GitLab, проверка и бэкап restic |
| `backup.sh` | Библиотека функций (дампы БД, restic, уведомления) |
| `db_scaner.sh` | Диагностика: какие СУБД есть на сервере (помогает заполнить `.env`) |
| `test_mail.sh` | Отправляет тестовое письмо для проверки настроек SMTP |
| `test_telegram.sh` | Отправляет тестовое сообщение в Telegram |

## Требования

- Linux с `bash`, `systemd` и cron (Debian/Ubuntu или RHEL-семейство);
- root-доступ (запуск через `sudo`);
- доступ к GitHub (для скачивания restic) и к restic REST-серверу;
- репозиторий на restic-сервере уже создан вручную.

## Установка

```bash
git clone <repo-url> restic
cd restic

cp .env.example .env
nano .env          # указать RESTIC_REPOSITORY и остальные настройки

sudo ./install.sh
```

Установщик:

1. проверит и при необходимости поставит зависимости (`curl`, `bzip2`, `gzip`, `cron`);
2. установит последнюю версию restic в `/usr/bin/restic` (или обновит, если уже стоит);
3. скопирует скрипты в `/root/scripts/backup`;
4. скопирует `.env` в `/root/scripts/backup/.env` (существующий `.env` не перезаписывается без `--force`);
5. добавит в crontab запуск `main.sh` по расписанию `BACKUP_CRON`;
6. включит и запустит службу cron.

## Настройка `.env`

`.env` — обычный bash-скрипт, поэтому списки задаются массивами.

### Репозиторий

`NAME` — имя сервера. Оно же используется как логин Basic Auth и как путь к репозиторию.

```bash
NAME="${NAME:-$(hostname)}"     # логин = NAME, путь = NAME
RESTIC_HOST="restic.example.com"
RESTIC_PORT="8000"
RESTIC_HTTP_PASSWORD="..."      # пароль Basic Auth REST-сервера
RESTIC_PASSWORD=""              # пароль самого репозитория
RESTIC_REPOSITORY="rest:http://${NAME}:${RESTIC_HTTP_PASSWORD}@${RESTIC_HOST}:${RESTIC_PORT}/${NAME}/"
```

- `RESTIC_HTTP_PASSWORD` — пароль Basic Auth REST-сервера, не пароль репозитория;
- `RESTIC_PASSWORD` — пароль самого репозитория; пусто = `--insecure-no-password`;
- итоговый URL: `rest:http://NAME:RESTIC_HTTP_PASSWORD@RESTIC_HOST:RESTIC_PORT/NAME/`.

### Что бэкапить

```bash
BACKUP_PATH="/"
BACKUP_EXCLUDE="/proc /run /sys /dev /tmp /var/cache /var/tmp /swap.img /var/lib/lxcfs"
RESTIC_ARGS=( "--pack-size" "128" "--tag=root" "--exclude-caches" "-x" )
```

### Списки БД

Поля разделены `|`. Значение `all` в поле базы означает дамп всех баз.
Дампы складываются в `DB_DUMP_PATH` (по умолчанию `/bak/db`).

Если задана хотя бы одна БД и её дамп завершился ошибкой, весь сценарий
останавливается: `restic backup` не запускается. Ошибка отправляется в Telegram/на почту.

```bash
DB_DUMP_PATH="/bak/db"

POSTGRES_BACKUPS=( "all|postgres" "mydb|postgres" )
MYSQL_BACKUPS=( "all|root" )

# "база|пользователь|контейнер"
POSTGRES_DOCKER_BACKUPS=( "all|postgres|postgres_container" )

# "база|пользователь|пароль|контейнер"
MONGO_DOCKER_BACKUPS=( "all|mongo_user|mongo_password|mongo_container" )
```

### Остальное

```bash
BACKUP_CRON="0 2 * * *"   # расписание cron
RESTIC_CHECK="no"          # yes = restic check перед бэкапом
GITLAB_BACKUP="no"         # yes = /opt/gitlab/bin/gitlab-backup
```

### Telegram

Уведомления отправляются при ошибках, если заданы токен и chat_id.

```bash
TG_TOKEN="123456789:AA..."                # токен бота
TG_CHAT_ID="-1001234567890"               # id чата/канала
PROXY="http://proxy.example.com:8080"     # пусто = подключаться напрямую
```

Если `api.telegram.org` недоступен напрямую, укажите `PROXY`.
Проверка:

```bash
./test_telegram.sh
# после установки:
sudo /root/scripts/backup/test_telegram.sh
```

### Почта

Письма отправляются при ошибках бэкапа (дамп БД, GitLab, restic check, restic backup).
Отправка идёт напрямую через SMTP с помощью `curl`, внешний MTA не нужен.

```bash
MAIL_FROM="backup@example.com"          # отправитель
MAIL_RCPT="admin@example.com"           # получатель; несколько — через запятую/пробел
SMTP_USER=""                            # логин SMTP; пусто = MAIL_FROM
MAIL_FROM_PASSWORD="app-password"       # пароль или пароль приложения
SMTP_AUTH="LOGIN"                       # пусто = авто; LOGIN = принудительно
SMTP_URL="smtp://smtp.example.com:587"  # smtp:// = STARTTLS, smtps:// = TLS сразу
SMTP_STARTTLS="yes"                     # no = relay без TLS (обычно порт 25)
MAIL_SUBJECT_PREFIX="Restic backup"     # префикс темы письма
```

- `smtp://host:587` — подключение и обязательный STARTTLS;
- `smtps://host:465` — TLS с самого начала;
- если SMTP не требует авторизации, оставьте `MAIL_FROM_PASSWORD` пустым;
- для Gmail, Яндекс.Почты и подобных обычно нужен «пароль приложения», а не пароль аккаунта;
- если curl падает с `(94) An authentication function returned an error`, сервер предлагает
  GSSAPI/NTLM раньше LOGIN — укажите `SMTP_AUTH="LOGIN"`.

Проверка настроек:

```bash
./test_mail.sh
# после установки:
sudo /root/scripts/backup/test_mail.sh
```

При ошибке отправки письма в лог `backup.log` пишется строка `** Ошибка отправки письма ...`.

## Ручной запуск

```bash
sudo /root/scripts/backup/main.sh
sudo tail -f /root/scripts/backup/backup.log
```

## Обновление

```bash
cd restic
git pull
sudo ./install.sh
```

`install.sh` обновит restic и скрипты. `.env` в `/root/scripts/backup` сохранится.
Чтобы перезаписать его версией из репозитория — `sudo ./install.sh --force`.

## Создание репозитория на restic-сервере

Выполняется вручную один раз (на restic-сервере или откуда есть доступ):

```bash
source .env
restic init --insecure-no-password -r "$RESTIC_REPOSITORY"
```

Если нужен пароль репозитория — уберите `--insecure-no-password` и задайте `RESTIC_PASSWORD`
в `.env`.

## Проверка содержимого репозитория

```bash
source .env
restic --insecure-no-password -r "$RESTIC_REPOSITORY" snapshots
```
