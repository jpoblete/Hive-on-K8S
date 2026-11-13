#!/usr/bin/env python3
# Usage Notice: This project is not meant for commercial use without permission and proper credit.
# Author: j.martinez.poblete@gmail.com
#
# Patches Hue's native Trino connector so interpreter options "catalog" and "schema"
# seed the session when the user's saved profile has none. Fails loudly if the
# expected source is not found, so a changed upstream cannot be patched silently.
import sys

PATH = "/usr/share/hue/desktop/libs/notebook/src/notebook/connectors/trino.py"

OLD = (
    "  @query_error_handler\n"
    "  def create_session(self, lang=None, properties=None):\n"
    "    properties = properties or self._get_session_info_from_user()\n"
)

NEW = (
    "  @query_error_handler\n"
    "  def create_session(self, lang=None, properties=None):\n"
    "    properties = properties or self._get_session_info_from_user()\n"
    "    if not properties:\n"
    "      # Seed the session from the interpreter options (catalog/schema) when the\n"
    "      # user has not picked a database yet.\n"
    "      # Only 'catalog' is a Trino session property. 'schema' is not one (it caused\n"
    "      # INVALID_SESSION_PROPERTY), so the schema is left to the fully qualified query.\n"
    "      seeded = {}\n"
    "      if self.options.get('catalog'):\n"
    "        seeded['catalog'] = self.options['catalog']\n"
    "      properties = seeded or None\n"
)

with open(PATH) as f:
    src = f.read()

if NEW in src:
    print("already patched")
    sys.exit(0)

if src.count(OLD) != 1:
    sys.exit("ERROR: expected create_session block not found exactly once; upstream changed")

with open(PATH, "w") as f:
    f.write(src.replace(OLD, NEW))

print("patched", PATH)
