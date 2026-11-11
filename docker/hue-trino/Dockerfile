# ---------------------------------------------------------------------------
# MODIFIED BY: j.martinez.poblete@gmail.com (Hive-on-K8S warehouse profile)
# Custom image. Origin: gethue/hue:latest (upstream, unmodified base).
# Purpose: Hue's bundled SQLAlchemy 1.3.8 cannot load sqlalchemy-trino, so this
# layer upgrades SQLAlchemy to 1.4.x and installs sqlalchemy-trino into Hue's own venv.
# Verified: sqlalchemy 1.4.54, sqlalchemy-trino 0.5.0, trino.sqlalchemy importable.
# ---------------------------------------------------------------------------
FROM gethue/hue:latest

USER root
RUN /usr/share/hue/build/env/bin/python -m pip install --no-cache-dir \
      "sqlalchemy>=1.4,<1.5" \
      "sqlalchemy-trino==0.5.0" \
      "trino==0.329.0" \
 && /usr/share/hue/build/env/bin/python -c "import sqlalchemy, trino.sqlalchemy; print('sqlalchemy', sqlalchemy.__version__, 'trino.sqlalchemy OK')"
USER hue
