# Usage Notice: This project is not meant for commercial use without permission and proper credit.
# Author: j.martinez.poblete@gmail.com
# Password-only Cassandra for Trino. Bakes the PasswordAuthenticator config into the image so the
# stock entrypoint's chown never hits a read-only ConfigMap mount.
FROM cassandra:4.1.12
USER root
COPY cassandra.yaml /etc/cassandra/cassandra.yaml
RUN chown cassandra:cassandra /etc/cassandra/cassandra.yaml && chmod 0644 /etc/cassandra/cassandra.yaml
USER cassandra
