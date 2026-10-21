#!/usr/bin/env bash
# Usage Notice: This project is not meant for commercial use without permission and proper credit.
# Author: j.martinez.poblete@gmail.com
# Idempotent lab bootstrap: create Ranger Hive service secure_hive (HS2 plugin target) and tune admin policies.
set -euo pipefail
NS="${1:-secure}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

kubectl exec -n "${NS}" ranger-0 -c ranger -- env NS="${NS}" python3 -c '
import json, urllib.request, base64, os, sys

props = {}
for path in os.popen("ls /opt/ranger/ranger-*/install.properties 2>/dev/null").read().split():
    for line in open(path):
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        k, v = line.split("=", 1)
        props[k] = v

auth = base64.b64encode(("admin:" + props["rangerAdmin_password"]).encode()).decode()
base = "http://127.0.0.1:6080/service/public/v2/api"


def req(method, path, body=None, timeout=30):
    data = None if body is None else json.dumps(body).encode()
    r = urllib.request.Request(base + path, data=data, method=method)
    r.add_header("Authorization", "Basic " + auth)
    r.add_header("Content-Type", "application/json")
    try:
        with urllib.request.urlopen(r, timeout=timeout) as resp:
            raw = resp.read().decode()
            return json.loads(raw) if raw else {}
    except urllib.error.HTTPError as e:
        body = e.read().decode()
        print("Ranger API error %s %s: %s" % (method, path, body), file=sys.stderr)
        raise


try:
    existing = req("GET", "/service/name/secure_hive")
    print("secure_hive already exists (id=%s)" % existing.get("id"))
except urllib.error.HTTPError as e:
    if e.code != 404:
        raise
    ns = os.environ["NS"]
    host = "hiveserver2-0.hiveserver2-headless.%s.svc.cluster.local" % ns
    jdbc = (
        "jdbc:hive2://%s:10000/;principal=hive/%s@SECURE.LAB" % (host, host)
    )
    body = {
        "isEnabled": True,
        "name": "secure_hive",
        "type": "hive",
        "configs": {
            "username": "hive",
            "password": "",
            "jdbc.driverClassName": "org.apache.hive.jdbc.HiveDriver",
            "jdbc.url": jdbc,
        },
        "description": "secure lab Hive (matches ranger-hive-security.xml)",
    }
    created = req("POST", "/service?forceSave=true", body, timeout=60)
    print("created secure_hive (id=%s)" % created.get("id"))
'

"${SCRIPT_DIR}/secure-ranger-admin-default-and-owner.sh" "${NS}"
