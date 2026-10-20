#!/usr/bin/env bash
# Usage Notice: This project is not meant for commercial use without permission and proper credit.
# Author: j.martinez.poblete@gmail.com
# Ranger lab: admin gets all Hive privileges on database "default" (+ tables/columns) and on any
# resource via existing {OWNER} policy rows (databases/tables/UDFs admin creates).
set -euo pipefail
NS="${1:-secure}"
kubectl exec -n "${NS}" ranger-0 -c ranger -- python3 -c '
import json, urllib.request, base64, os

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

ALL_ACCESSES = [
    {"type": t, "isAllowed": True}
    for t in (
        "select", "update", "create", "drop", "alter", "index", "lock", "all",
        "read", "write", "repladmin", "serviceadmin", "tempudfadmin", "refresh",
    )
]


def req(method, path, body=None):
    data = None if body is None else json.dumps(body).encode()
    r = urllib.request.Request(base + path, data=data, method=method)
    r.add_header("Authorization", "Basic " + auth)
    r.add_header("Content-Type", "application/json")
    with urllib.request.urlopen(r, timeout=30) as resp:
        return json.loads(resp.read().decode())


def resource_is_global_star(resources):
    for spec in resources.values():
        vals = spec.get("values") or []
        if "*" in vals:
            return True
    return False


policies = req("GET", "/service/secure_hive/policy")
removed = 0
default_updated = False
owner_rows = 0

for p in policies:
    changed = False
    resources = p.get("resources") or {}
    name = p.get("name") or ""

    # Drop admin from global (*) policies; hive + {OWNER} rows stay.
    if resource_is_global_star(resources):
        for item in p.get("policyItems", []):
            users = item.get("users") or []
            if "admin" in users and "{OWNER}" not in users:
                item["users"] = [u for u in users if u != "admin"]
                changed = True
                removed += 1

    # default DB: database=default, table/column=* — full access for admin.
    db_vals = (resources.get("database") or {}).get("values") or []
    if db_vals == ["default"] and "table" in resources and "column" in resources:
        admin_item = None
        for item in p.get("policyItems", []):
            if "admin" in (item.get("users") or []):
                admin_item = item
                break
        if admin_item is None:
            p.setdefault("policyItems", []).append(
                {"users": ["admin"], "accesses": ALL_ACCESSES, "delegateAdmin": True}
            )
            changed = True
            default_updated = True
        else:
            admin_item["accesses"] = ALL_ACCESSES
            admin_item["delegateAdmin"] = True
            changed = True
            default_updated = True

    for item in p.get("policyItems", []):
        if "{OWNER}" in (item.get("users") or []):
            acc = item.get("accesses") or []
            if not any(a.get("type") == "all" and a.get("isAllowed") for a in acc):
                item["accesses"] = [{"type": "all", "isAllowed": True}]
                changed = True
            owner_rows += 1

    if changed:
        req("PUT", "/policy/" + str(p["id"]), p)

print("removed_admin_from_global_policy_items:", removed)
print("default_db_admin_policy_updated:", default_updated)
print("owner_policy_rows_seen:", owner_rows)
'
