#!/usr/bin/env bash
# Usage Notice: This project is not meant for commercial use without permission and proper credit.
# Author: j.martinez.poblete@gmail.com
# Apply the bigdata schema and trino grants to postgres-0. Idempotent; safe to re-run.
# Creates/updates the trino LOGIN role password from the hive-credentials Secret (postgres-trino-password),
# then runs bigdata-schema.sql. Run from anywhere; needs kubectl access to namespace warehouse.
set -euo pipefail

NS="${NS:-warehouse}"
POD="${POD:-postgres-0}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

PW="$(kubectl -n "${NS}" get secret hive-credentials -o jsonpath='{.data.postgres-trino-password}' | base64 -d)"
if [ -z "${PW}" ]; then
  echo "error: postgres-trino-password missing from hive-credentials in ${NS}" >&2
  exit 1
fi

# Create the trino role if absent, otherwise reset its password to the Secret value.
kubectl -n "${NS}" exec -i "${POD}" -- psql -U postgres -d bigdata -v ON_ERROR_STOP=1 -v pw="${PW}" <<'SQL'
SELECT NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'trino') AS need_create \gset
\if :need_create
  CREATE ROLE trino LOGIN;
\endif
ALTER ROLE trino LOGIN PASSWORD :'pw';
SQL

# Apply schema, grants, and sample data.
kubectl -n "${NS}" exec -i "${POD}" -- psql -U postgres -d bigdata -v ON_ERROR_STOP=1 < "${HERE}/bigdata-schema.sql"

echo "applied bigdata schema and trino grants to ${POD} (${NS})"
