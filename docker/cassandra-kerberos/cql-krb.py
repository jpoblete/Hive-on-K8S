#!/usr/bin/env python3
# Usage Notice: This project is not meant for commercial use without permission and proper credit.
# Author: j.martinez.poblete@gmail.com
# Kerberos (GSSAPI) CQL client for the warehouse Cassandra cluster.
# stock cqlsh only supports username/password, so it cannot use the Instaclustr authenticator.
# Usage (inside a cassandra pod, after a ticket exists from the entrypoint kinit):
#   python3 /usr/local/bin/cql-krb.py                      # runs a sanity query
#   python3 /usr/local/bin/cql-krb.py "SELECT * FROM system_schema.keyspaces;"
import os, socket, sys
from cassandra import ConsistencyLevel
from cassandra.cluster import Cluster, ExecutionProfile, EXEC_PROFILE_DEFAULT
from cassandra.auth import AuthProvider, SaslAuthenticator

# QUORUM by default: with RF=3 it tolerates one replica being down/unreachable (never ALL).
# Override with CQL_CONSISTENCY=LOCAL_QUORUM, ONE, etc. if needed.
CONSISTENCY = getattr(ConsistencyLevel, os.environ.get("CQL_CONSISTENCY", "QUORUM").upper())

class FqdnGssapiProvider(AuthProvider):
    # The driver builds the GSSAPI principal from the peer address. Canonicalize the peer IP to
    # its reverse-DNS FQDN so GSSAPI requests cassandra/<fqdn>@REALM, which the keytabs contain.
    def new_authenticator(self, host):
        return SaslAuthenticator(socket.getfqdn(host), 'cassandra', mechanism='GSSAPI', qop='auth')

contact = socket.getfqdn('cassandra-0.cassandra-headless')
query = sys.argv[1] if len(sys.argv) > 1 else "SELECT release_version FROM system.local;"
profile = ExecutionProfile(consistency_level=CONSISTENCY)
cluster = Cluster([contact], port=9042, auth_provider=FqdnGssapiProvider(),
                  execution_profiles={EXEC_PROFILE_DEFAULT: profile})
session = cluster.connect()
for row in session.execute(query):
    print(row)
cluster.shutdown()
