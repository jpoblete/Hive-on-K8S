# Usage Notice: This project is not meant for commercial use without permission and proper credit.
# Author: j.martinez.poblete@gmail.com
# Docker Hub apache/ranger:2.4.0 is a single linux/arm64 manifest. Kind on Apple Silicon
# runs that tag. amd64 clusters need this image: same Admin tree, amd64 Ubuntu + Java 8.
FROM --platform=linux/arm64 apache/ranger:2.4.0 AS src

FROM --platform=linux/amd64 ubuntu:20.04

ENV DEBIAN_FRONTEND=noninteractive \
    JAVA_HOME=/usr/lib/jvm/java-8-openjdk-amd64 \
    RANGER_HOME=/opt/ranger \
    PATH=/usr/lib/jvm/java-8-openjdk-amd64/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
         openjdk-8-jdk-headless python3 python-is-python3 ca-certificates procps bc \
    && rm -rf /var/lib/apt/lists/* \
    && groupadd -g 1000 ranger \
    && useradd -u 1000 -g 1000 -m -s /bin/bash ranger

COPY --from=src /opt/ranger /opt/ranger

USER root
RUN mkdir -p /var/run/ranger /var/log/ranger \
    && chown ranger:ranger /var/run/ranger /var/log/ranger
USER ranger
WORKDIR /opt/ranger
