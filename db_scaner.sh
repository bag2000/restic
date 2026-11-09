#!/bin/bash

# Диагностика: какие СУБД и на каких портах есть на сервере.
# Помогает заполнить списки POSTGRES_BACKUPS/MYSQL_BACKUPS/... в .env.

echo "=== Docker/Podman ==="
docker ps 2>/dev/null | rg -i "mysql|postgres|mongo|redis|postgre|mariadb"
podman ps 2>/dev/null | rg -i "mysql|postgres|mongo|redis|postgre|mariadb"
echo ""
echo "=== DPKG/RPM ==="
dpkg -l 2>/dev/null | rg -i "mysql|postgresql|mongo|redis|mariadb"
rpm -qa 2>/dev/null | rg -i "mysql|postgres|mongo|redis|mariadb"
echo ""
echo "=== Ports ==="
sudo ss -tlnp | grep -E ':(3306|5432|27017|6379|1433|1521|3307)'
echo ""
echo "=== Systemctl ==="
systemctl list-units --type=service --all | rg -i "sql|postgres|mysql|mongo|redis"
