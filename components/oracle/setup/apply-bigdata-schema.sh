#!/usr/bin/env bash
# Usage Notice: This project is not meant for commercial use without permission and proper credit.
# Author: j.martinez.poblete@gmail.com
# Apply the oracle.bigdata schema and trino grants to oracle-0 (FREEPDB1). Idempotent; safe to re-run.
# Sets the TRINO user's password from the hive-credentials Secret (oracle-trino-password), creating the
# Secret key first if missing. Needs kubectl access to namespace warehouse.
set -euo pipefail

NS="${NS:-warehouse}"
POD="${POD:-oracle-0}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Ensure the trino password exists in the Secret (generated once, then reused).
if ! kubectl -n "${NS}" get secret hive-credentials -o jsonpath='{.data.oracle-trino-password}' 2>/dev/null | grep -q .; then
  NEWPW="$(openssl rand -base64 24 | tr -d '=+/' | cut -c1-24)"
  kubectl -n "${NS}" patch secret hive-credentials -p "{\"stringData\":{\"oracle-trino-password\":\"${NEWPW}\"}}" >/dev/null
fi
PW="$(kubectl -n "${NS}" get secret hive-credentials -o jsonpath='{.data.oracle-trino-password}' | base64 -d)"

# Apply schema and grants as SYSDBA in FREEPDB1.
kubectl -n "${NS}" exec -i "${POD}" -- bash -c 'sqlplus -s / as sysdba' < "${HERE}/bigdata-schema.sql"

# Set the real TRINO password (the SQL sets a placeholder first).
kubectl -n "${NS}" exec -i "${POD}" -- bash -c "sqlplus -s / as sysdba" <<SQL
ALTER SESSION SET CONTAINER = FREEPDB1;
ALTER USER trino IDENTIFIED BY "${PW}";
SQL

echo "applied oracle bigdata schema and trino grants to ${POD} (${NS}, FREEPDB1)"
