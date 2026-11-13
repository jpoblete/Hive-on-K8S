# Usage Notice: This project is not meant for commercial use without permission and proper credit.
# Author: j.martinez.poblete@gmail.com
# Throwaway helper: the Cassandra image has keytool but no openssl. This adds
# openssl so PEM key/cert material can be converted to a JKS keystore and
# truststore in-cluster, without keys leaving the cluster.
FROM jpoblete73/cassandra-kerberos:4.1.12
USER root
RUN (apt-get update && apt-get install -y --no-install-recommends openssl && rm -rf /var/lib/apt/lists/*) \
    || (apk add --no-cache openssl)
