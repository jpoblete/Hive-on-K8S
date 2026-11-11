#!/bin/bash
# Usage Notice: This project is not meant for commercial use without permission and proper credit.
# Author: j.martinez.poblete@gmail.com
# Wrapper around cql-krb.py (GSSAPI CQL client) for the warehouse Cassandra Kerberos ring.
#
# Usage (inside a cassandra pod, after the entrypoint kinit):
#   cql.sh                                   # sanity query (system.local)
#   cql.sh "SELECT * FROM system_schema.keyspaces;"
#   cql.sh -f ddl.cql                        # run statements from a file (one per ';')
set -euo pipefail

CLIENT="/usr/local/bin/cql-krb.py"
[ -x "${CLIENT}" ] || CLIENT="$(dirname "$(readlink -f "$0")")/cql-krb.py"

if [ "${1:-}" = "-f" ]; then
  [ -n "${2:-}" ] && [ -r "$2" ] || { echo "usage: cql.sh -f <file.cql>" >&2; exit 2; }
  # Each statement is executed separately; cql-krb.py takes one query per invocation.
  statements="$(tr '\n' ' ' < "$2" | sed 's/;[[:space:]]*/;\n/g')"
  while IFS= read -r stmt; do
    stmt="$(echo "${stmt}" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
    [ -z "${stmt}" ] && continue
    echo ">> ${stmt}"
    python3 "${CLIENT}" "${stmt}"
  done <<< "${statements}"
else
  python3 "${CLIENT}" "$@"
fi
