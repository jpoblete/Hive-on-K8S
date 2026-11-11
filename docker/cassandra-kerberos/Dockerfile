# Usage Notice: This project is not meant for commercial use without permission and proper credit.
# Author: j.martinez.poblete@gmail.com
# Apache Cassandra 4.1.12 + Instaclustr Kerberos authenticator, REBUILT against Cassandra 4.1.12.
# The upstream cassandra-kerberos 4.1.0-1.0.0 jar calls SelectStatement.execute(QueryState,QueryOptions,long),
# which no longer matches Cassandra 4.1.12 internals (NoSuchMethodError on role lookup). We compile the
# upstream 4.1.0 source against cassandra-all:4.1.12 in a build stage and ship only that jar.
# 5.0.x is not supported by the authenticator, hence 4.1.x.

# ---- Stage 1: compile the authenticator against Cassandra 4.1.12 ----
FROM maven:3.9-eclipse-temurin-11 AS authenticator-builder
WORKDIR /build
COPY authenticator-src/ ./
RUN mvn -q -B -DskipTests package \
    && cp cassandra-4.1/target/cassandra-kerberos-4.1.12-1.0.0.jar /cassandra-kerberos-4.1.12.jar

# ---- Stage 2: runtime image ----
FROM cassandra:4.1.12

USER root
# Kerberos client tools (kinit/klist/kdestroy) for manual auth testing, plus a home
# directory for the cassandra user so cqlsh can save its history file.
# python3-cassandra + python3-gssapi/kerberos/pure-sasl let us exercise the Instaclustr
# SASL/GSSAPI authenticator from a real client (stock cqlsh only does username/password).
RUN apt-get update \
    && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
         krb5-user python3-cassandra python3-kerberos python3-gssapi python3-pure-sasl \
    && rm -rf /var/lib/apt/lists/* \
    && mkdir -p /home/cassandra && chown cassandra:cassandra /home/cassandra

COPY cassandra.yaml /etc/cassandra/cassandra.yaml
RUN chown cassandra:cassandra /etc/cassandra/cassandra.yaml && chmod 0644 /etc/cassandra/cassandra.yaml

# Replace any stock authenticator jar with the 4.1.12-compiled build.
COPY --from=authenticator-builder /cassandra-kerberos-4.1.12.jar /opt/cassandra/lib/cassandra-kerberos-4.1.12.jar
RUN chown cassandra:cassandra /opt/cassandra/lib/cassandra-kerberos-4.1.12.jar \
    && python3 -c "import sys,zipfile; sys.exit(0 if 'com/instaclustr/cassandra/auth/KerberosAuthenticator.class' in zipfile.ZipFile(sys.argv[1]).namelist() else 1)" /opt/cassandra/lib/cassandra-kerberos-4.1.12.jar

COPY docker-entrypoint-krb5.sh /usr/local/bin/docker-entrypoint-krb5.sh
RUN chmod 0755 /usr/local/bin/docker-entrypoint-krb5.sh
# Kerberos CQL client for troubleshooting (stock cqlsh cannot do GSSAPI).
COPY cql-krb.py /usr/local/bin/cql-krb.py
RUN chmod 0755 /usr/local/bin/cql-krb.py
# Wrapper so DDL/DML can be run as `cql.sh "<statement>"` or `cql.sh -f file.cql`.
COPY cql.sh /usr/local/bin/cql.sh
RUN chmod 0755 /usr/local/bin/cql.sh
USER cassandra
ENTRYPOINT ["/usr/local/bin/docker-entrypoint-krb5.sh"]
CMD ["cassandra", "-f"]
