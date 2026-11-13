#!/usr/bin/env bash
# Usage Notice: This project is not meant for commercial use without permission and proper credit.
# Author: j.martinez.poblete@gmail.com
# Apply the mysql.bigdata database and trino grants to mysql-0. Idempotent; safe to re-run.
# Sets the trino user's password from hive-credentials (mysql-trino-password), creating it if missing.
set -euo pipefail

NS="${NS:-warehouse}"
POD="${POD:-mysql-0}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if ! kubectl -n "${NS}" get secret hive-credentials -o jsonpath='{.data.mysql-trino-password}' 2>/dev/null | grep -q .; then
  NEWPW="$(openssl rand -base64 24 | tr -d '=+/' | cut -c1-24)"
  kubectl -n "${NS}" patch secret hive-credentials -p "{\"stringData\":{\"mysql-trino-password\":\"${NEWPW}\"}}" >/dev/null
fi
PW="$(kubectl -n "${NS}" get secret hive-credentials -o jsonpath='{.data.mysql-trino-password}' | base64 -d)"

# Schema, sample data, and grants (root from the pod's MYSQL_ROOT_PASSWORD).
kubectl -n "${NS}" exec -i "${POD}" -- sh -c 'mysql -uroot -p"$MYSQL_ROOT_PASSWORD"' < "${HERE}/bigdata-schema.sql"

# Set the real trino password (the SQL sets a placeholder first).
kubectl -n "${NS}" exec -i "${POD}" -- sh -c 'mysql -uroot -p"$MYSQL_ROOT_PASSWORD"' <<SQL
ALTER USER 'trino'@'%' IDENTIFIED BY '${PW}';
SQL

echo "applied mysql bigdata database and trino grants to ${POD} (${NS})"
