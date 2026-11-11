#!/bin/bash
# Usage Notice: This project is not meant for commercial use without permission and proper credit.
# Author: j.martinez.poblete@gmail.com
# Generate per-node cassandra-krb5.properties from POD_NAME, then hand off to the stock entrypoint.
set -euo pipefail
REALM="${KRB5_REALM:-WAREHOUSE.LAB}"
HOST="$(hostname -f)"
CONF_DIR=/etc/cassandra

# Reverse-DNS check (Instaclustr GSSAPI requirement): the pod's IP must reverse-resolve
# to its FQDN, and that FQDN must forward-resolve back to the same IP. Fail fast otherwise.
verify_reverse_dns(){
  local ip fwd rev
  ip="$(hostname -i | awk '{print $1}')"
  rev="$(getent hosts "${ip}" | awk '{print $2}' | head -1)"
  fwd="$(getent hosts "${HOST}" | awk '{print $1}' | head -1)"
  if [ -z "${rev}" ] || [ "${rev}" != "${HOST}" ]; then
    echo "DNS check FAILED: reverse lookup of ${ip} gave '${rev:-<none>}', expected ${HOST}" >&2
    exit 1
  fi
  if [ "${fwd}" != "${ip}" ]; then
    echo "DNS check FAILED: forward lookup of ${HOST} gave '${fwd:-<none>}', expected ${ip}" >&2
    exit 1
  fi
  echo "DNS check OK: ${HOST} <-> ${ip}"
}
verify_reverse_dns
cat > "${CONF_DIR}/cassandra-krb5.properties" <<PROPS
service_principal=cassandra/${HOST}@${REALM}
keytab=/etc/cassandra/keytab/${POD_NAME}.keytab
qop=auth
PROPS

# Obtain a Kerberos ticket for the cassandra user on login (container start) using this
# pod's host keytab, so kinit/klist/cqlsh-over-GSSAPI work without a manual kinit. The
# server authenticates with the same keytab itself, so a kinit failure is logged but
# does not block Cassandra startup.
KEYTAB="/etc/cassandra/keytab/${POD_NAME}.keytab"
PRINCIPAL="cassandra/${HOST}@${REALM}"
if kinit -kt "${KEYTAB}" "${PRINCIPAL}" 2>/tmp/kinit.err; then
  echo "kinit OK: ${PRINCIPAL}"
else
  echo "kinit WARNING: could not obtain ticket for ${PRINCIPAL}: $(cat /tmp/kinit.err)" >&2
fi
exec docker-entrypoint.sh "$@"
