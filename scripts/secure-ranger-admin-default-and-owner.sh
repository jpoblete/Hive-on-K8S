#!/usr/bin/env bash
# Usage Notice: This project is not meant for commercial use without permission and proper credit.
# Author: j.martinez.poblete@gmail.com
# Ranger lab: Kerberos admin/admin is a Hive superuser (every global * policy), and {OWNER}
# rows stay so creators keep access to objects they own.
set -euo pipefail
NS="${1:-secure}"
kubectl exec -n "${NS}" ranger-0 -c ranger -- python3 -c '
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
    try:
        with urllib.request.urlopen(r, timeout=30) as resp:
            return json.loads(resp.read().decode())
    except urllib.error.HTTPError as e:
        err = e.read().decode()
        raise RuntimeError("%s %s failed (%s): %s" % (method, path, e.code, err)) from e


def resource_is_global_star(resources):
    for spec in resources.values():
        vals = spec.get("values") or []
        if "*" in vals:
            return True
    return False


def ensure_admin_superuser(policy):
    items = policy.setdefault("policyItems", [])
    target = None
    for item in items:
        users = item.get("users") or []
        if "{OWNER}" in users:
            continue
        if "admin" in users:
            target = item
            break
        if "hive" in users and target is None:
            target = item
    if target is None:
        items.append({"users": ["admin"], "accesses": ALL_ACCESSES, "delegateAdmin": True})
        return True
    changed = False
    users = list(target.get("users") or [])
    if "admin" not in users:
        target["users"] = users + ["admin"]
        changed = True
    if target.get("accesses") != ALL_ACCESSES:
        target["accesses"] = ALL_ACCESSES
        changed = True
    if not target.get("delegateAdmin"):
        target["delegateAdmin"] = True
        changed = True
    return changed


policies = req("GET", "/service/secure_hive/policy")
admin_global = 0
default_updated = False
owner_rows = 0

for p in policies:
    changed = False
    resources = p.get("resources") or {}
    name = p.get("name") or ""

    # admin/admin@SECURE.LAB is the lab superuser on every global (*) policy.
    if resource_is_global_star(resources) and ensure_admin_superuser(p):
        changed = True
        admin_global += 1

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
        try:
            req("PUT", "/policy/" + str(p["id"]), p)
        except RuntimeError as err:
            print("policy_update_skipped:", p.get("name"), err, file=sys.stderr)

print("admin_global_policies_updated:", admin_global)
print("default_db_admin_policy_updated:", default_updated)
print("owner_policy_rows_seen:", owner_rows)
'
