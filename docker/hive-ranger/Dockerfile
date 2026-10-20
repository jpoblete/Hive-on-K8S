# Usage Notice: This project is not meant for commercial use without permission and proper credit.
# Author: j.martinez.poblete@gmail.com
# apache/hive:nightly + Ranger hive-agent (RANGER_GIT_REF=master) jars; build dist/ first: ./build-ranger-hive-plugin.sh
FROM apache/hive:nightly
USER root
# dist/jars/ populated by build-ranger-hive-plugin.sh (Ranger 2.4.0 plugin + REST client deps; no Hive 3.x jars).
COPY dist/jars/*.jar /opt/hive/lib/
# nightly: javax.ws.rs-api 2.0.1 and beeline-standalone embed JAX-RS 2.0; Ranger REST needs 2.1+ (dist/jars).
# Hive HS2 classpath is lib/*.jar in glob order; prefix copy so MultivaluedMap.addAll resolves before beeline jar.
RUN rm -f /opt/hive/lib/javax.ws.rs-api-2.0.1.jar /opt/hive/lib/jersey-multipart-1.19*.jar \
    /opt/hive/hcatalog/share/webhcat/svr/lib/javax.ws.rs-api-2.0.1.jar \
 && cp /opt/hive/lib/jakarta.ws.rs-api-2.1.6.jar /opt/hive/lib/000-ranger-jakarta.ws.rs-api-2.1.6.jar \
 && mkdir -p /opt/hive/beeline-client \
 && if [ -f /opt/hive/lib/hive-beeline-*-standalone.jar ]; then \
      mv /opt/hive/lib/hive-beeline-*-standalone.jar /opt/hive/beeline-client/; \
    fi \
 && mv /opt/hive/bin/beeline /opt/hive/bin/beeline-via-hive \
 && printf '%s\n' '#!/usr/bin/env bash' 'set -euo pipefail' \
    'jar=$(echo /opt/hive/beeline-client/hive-beeline-*-standalone.jar)' \
    'export JLINE_TERMINAL=dumb' \
    'exec java -Dorg.jline.terminal.type=dumb -jar "${jar}" "$@"' > /opt/hive/bin/beeline \
 && chmod +x /opt/hive/bin/beeline \
 && find /opt/hadoop -path '*/lib/jersey-*.jar' -delete \
 && mkdir -p /opt/hive/ranger/policycache && chown -R hive:hive /opt/hive/ranger 2>/dev/null || true
USER hive
