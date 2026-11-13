# ---------------------------------------------------------------------------
# MODIFIED BY: j.martinez.poblete@gmail.com (BigData-on-K8S warehouse profile)
# Custom image. Origin: gethue/hue:latest (upstream).
# Purpose: the native Hue Trino connector (notebook/connectors/trino.py) builds the
# session only from the user's saved profile. Interpreter options "catalog"/"schema"
# are ignored, so the "Trino Cassandra" editor fails with MISSING_CATALOG_NAME until
# a database is picked in the left panel. This layer makes create_session() seed the
# Trino "catalog" session property from the interpreter options when the profile has
# none. "schema" is not a Trino session property and is intentionally not seeded.
# ---------------------------------------------------------------------------
FROM gethue/hue:latest

USER root
COPY patch_trino_session.py /tmp/patch_trino_session.py
RUN /usr/share/hue/build/env/bin/python /tmp/patch_trino_session.py \
 && rm -f /tmp/patch_trino_session.py
USER hue
