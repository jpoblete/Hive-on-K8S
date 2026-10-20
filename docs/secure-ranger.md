# Apache Ranger on `secure`

Kerberos on **`secure`** handles **authentication**; Ranger adds **authorization** (policies) and **audit**. Hive/HDFS **plugins are not enabled yet** — only Phase **1** (Admin UI) is scaffolded in git.

See [secure-profile.md](secure-profile.md) for the running stack.

## Status

| Phase | What | Repo state |
|-------|------|------------|
| **1** | Ranger Admin + MySQL (`apache/ranger:2.4.0`) | **`components/ranger`**, **`overlays/secure/ranger`** — opt-in |
| **2** | Hive plugin on HS2 (`apache/hive:nightly`) | **`docker/hive-ranger`**, **`overlays/secure/hiveserver2-ranger`**, `HIVECTL_SECURE_RANGER_HS2=1` |
| **3** | HDFS plugin on NameNode | Pending |
| **4** | HMS pre-event + Hue | Pending |

Default **`./hiveCtl.sh start secure`** does **not** start Ranger. Enable with env or start the component alone.

## Phase 1 — try Ranger Admin (lab)

**Prerequisites:** `secure` MySQL up, **~2 GiB** free on Docker disk for the Ranger image (~1 GiB), **`mysql-0` Ready**.

```bash
# After secure stack is up (or full stack with Ranger):
./hiveCtl.sh start secure ranger
# Or enable for full stack starts:
HIVECTL_SECURE_RANGER=1 ./hiveCtl.sh start secure

# hiveCtl starts kubectl port-forward to localhost:6080 (same pattern as Hue on :8888).
# Browser: http://127.0.0.1:6080/login.jsp
# Disable: HIVECTL_RANGER_PORT_FORWARD=0
# Manual fallback: kubectl port-forward -n secure svc/ranger 6080:6080
```

**Hue** on `llap` / `secure` uses the same mechanism at **http://localhost:8888/** (`HIVECTL_HUE_PORT_FORWARD=0` to disable).

**Browser URL:** use **http://127.0.0.1:6080/login.jsp** (matches `policymgr_external_url` in the overlay). If you use a different host/port, set **`RANGER_EXTERNAL_URL`** on the render init container (via kustomize) or login may loop back to the login page.

**Credentials** (stored in Secret `hive-credentials` on first start; Ranger requires upper+lower+digit in the admin password):

```bash
kubectl get secret hive-credentials -n secure -o jsonpath='{.data.ranger-admin-password}' | base64 -d; echo
# UI user: admin   password: <ranger-admin-password above>
```

**What the overlay does**

1. **`ranger-mysql-init` Job** — creates DB `ranger` and user `rangeradmin` on `mysql.secure.svc.cluster.local`.
2. **Init container** — renders `install.properties` from templates + secrets (root + ranger DB passwords).
3. **`ranger-0` StatefulSet** — runs upstream **`apache/ranger:2.4.0`** (Admin only; **DB audit**, no Solr).

**Service Manager UI:** The grid lists every row in **`x_service_def`**. Ranger 2.4 only *creates* embedded plugin types listed in **`policymgr_supportedcomponents`** / **`ranger.supportedcomponents`** (comma-separated: **`hive,hdfs`** here — the install template comment about semicolons is wrong upstream). That filter runs **once** when the Admin JVM bootstraps the DB; changing XML later does not remove types already inserted. After upgrading this overlay, re-seed once:

```bash
./hiveCtl.sh stop secure ranger
HIVECTL_RANGER_REINIT=1 ./hiveCtl.sh start secure ranger
# Same admin password as before unless ensureRangerSecrets rotated it.
```

Then Service Manager should show only **HDFS** and **Hadoop SQL** (Hive). No `dev_*` demo services are created (Phase 1 skips `create-ranger-services.py`).

**Stop / retry**

```bash
./hiveCtl.sh stop secure ranger   # deletes Job + ranger StatefulSet
./hiveCtl.sh start secure ranger    # re-runs MySQL init Job
```

**Apple Silicon / Kind:** Docker Hub’s **`apache/ranger:2.4.0`** is **linux/amd64**. Kind on Mac may run it under emulation (slower first start). Hive **nightly** remains **arm64** with **x86_64** Hadoop natives — separate issue for Phase 2.

**Smoke checks**

```bash
kubectl get pods -n secure -l app=ranger
kubectl logs -n secure ranger-0 -c ranger --tail=50
curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:6080/login.jsp   # via port-forward
```

If Admin stays in CrashLoop, inspect logs for MySQL connectivity or failed `setup.sh` (wrong password, DB missing).

## Backup and restore (policies)

Ranger stores policies in MySQL database **`ranger`** on **`mysql-0`**. **`./hiveCtl.sh backup secure`** stops Ranger Admin (when running), then writes **`mysql-ranger.sql`** alongside the Hive metastore and HDFS archives. If Ranger was never started, backup skips the Ranger file and prints a hint.

**Restore:** **`./hiveCtl.sh restore secure <backup-dir>`** loads **`mysql-ranger.sql`** when present (after **`mysql-hive.sql`**, before HDFS). It creates the **`rangeradmin`** user if needed, then imports the dump so **`secure_hive`** and policies reappear without re-running the UI setup.

```bash
./hiveCtl.sh backup secure
# optional: HIVECTL_SECURE_RANGER=1 for full stack including Ranger on restore
./hiveCtl.sh restore secure ./backups/secure-YYYYMMDD-HHMMSS
```

After restore with Phase 2 HS2, rebuild/load the custom image if Kind pruned it (`docker/hive-ranger/README.md`), then **`HIVECTL_SECURE_RANGER_HS2=1 ./hiveCtl.sh start secure hiveserver2`**. Wait ~30s for policy poll or restart HS2 before testing authorization.

## Architecture (target)

```text
mysql  ── hive DB + ranger DB
ranger-0  (6080)  ◄── policy REST ──  (future) HS2 / NN plugins
krb5kdc → hadoop → zookeeper → hivemetastore×2 → llapdaemon×2 → hiveserver2×2 → hue
```

**Start order (with Ranger):** `krb5kdc → hadoop-namenode → mysql → **ranger** → zookeeper → …`

## Phase 2 — Hive plugin (next implementation)

### DoAs / impersonation (required for Ranger)

With **Ranger** as the authorization plugin, Hive must **not** impersonate end users on HDFS/YARN. The **`secure`** overlay is aligned for Phase 2:

| Property | Value | Where |
|----------|-------|--------|
| `hive.server2.enable.doAs` | **`false`** | HS2, LLAP (`hive-site.xml`) |
| `hive.metastore.execute.setugi` | **`false`** | HMS, HS2, LLAP |
| `hive.metastore.event.db.notification.api.auth` | **`false`** | HMS, HS2 (Kerberos lab without full `hadoop.proxyuser.hive.*`) |

HS2 still authenticates clients (Kerberos); **Ranger** evaluates the session user. Work runs as the **`hive`** service principal. If you later enable **`doAs=true`**, you must configure **`hadoop.proxyuser.hive.hosts`** / **`.groups`** in `core-site.xml` and typically set **`hive.metastore.event.db.notification.api.auth=true`** — that path conflicts with the usual Ranger posture ([Hive threat model](https://github.com/apache/hive/blob/master/THREAT_MODEL.md)).

After changing these properties, restart **HMS**, **HS2**, and **LLAP** (`./hiveCtl.sh restart secure hiveserver2` etc.).

Stock **`apache/hive:nightly`** has **no** Ranger jars. This repo ships:

1. **`docker/hive-ranger/build-ranger-hive-plugin.sh`** — builds **`hive-agent`** from **Ranger `master`** (Hive **4.3 nightly** API); REST deps from Maven + **`apache/ranger:2.4.0`** Admin image as fallback.
2. **`docker/hive-ranger/Dockerfile`** — `FROM apache/hive:nightly`, copies plugin JARs into `/opt/hive/lib`.
3. HS2 overlay injects **`ranger.plugin.hive.policy.rest.client.*`** (admin password from **`hive-credentials`**) because Phase 1 Admin uses local login, not Kerberos SPNEGO.
3. **`overlays/secure/hiveserver2-ranger`** — Ranger XML + HS2 authorizer properties; opt-in with **`HIVECTL_SECURE_RANGER_HS2=1`**.

```bash
cd docker/hive-ranger && ./build-ranger-hive-plugin.sh
docker build -t hive-on-k8s/hive-ranger:2.4.0-nightly .
kind load docker-image hive-on-k8s/hive-ranger:2.4.0-nightly   # if using Kind

./hiveCtl.sh start secure ranger
# Ranger UI: create Hive service named secure_hive (matches ranger-hive-security.xml)

HIVECTL_SECURE_RANGER_HS2=1 ./hiveCtl.sh stop secure hiveserver2
HIVECTL_SECURE_RANGER_HS2=1 ./hiveCtl.sh start secure hiveserver2
```

Plugin REST URL: **`http://ranger.secure.svc.cluster.local:6080`**. Service name **`secure_hive`**.

6. Smoke: deny/allow via Beeline with Kerberos. Lab **`admin`** (`admin/admin@SECURE.LAB`) should have **all** privileges on **`default`** and on databases/tables/UDFs **they own** (`{OWNER}` rows), not on every database:

```bash
./scripts/secure-ranger-admin-default-and-owner.sh secure
# Wait ~30s (policy poll) or restart HS2, then re-run the query as admin.
```

**LLAP:** Enforcement stays on the **HS2** session path; no separate LLAP daemon plugin in most deployments.

**Metastore (Hive 4):** Optional **`hive.metastore.pre.event.listeners`** with `HiveMetaStoreAuthorizer` after HS2 policies work ([HIVE-21753](https://issues.apache.org/jira/browse/HIVE-21753)).

## Phase 3 — HDFS plugin

Install **`ranger-hdfs-plugin`** on **`hadoop-namenode-0`**, register HDFS service in Admin (`nameservice`), restart NN. Requires plugin build matching **Hadoop 3.4.1** in this repo.

## Kerberos (later)

Phase 1 Admin uses **local** Ranger users (`admin` + generated password). For SPNEGO/Kerberos on Admin and plugin keytabs:

- Add to **`secure-lab-hosts.list`**:  
  `ranger-0.ranger-headless.secure.svc.cluster.local|ranger|ranger-0`
- `./hiveCtl.sh resync-keytabs secure` and restart **`ranger-0`**.

## Files in this repo

```text
components/ranger/           # Admin StatefulSet, Service, ConfigMap template
overlays/secure/ranger/      # MySQL init Job, secret-render init, namespace patches
hiveCtl.sh                   # ensureRangerSecrets, HIVECTL_SECURE_RANGER, start/stop ranger
```

## Open decisions

1. **Pin Ranger** — Stay on **2.4.0** image vs build **3.x** against Hive 4.3 nightly.
2. **Custom Hive image** — Single **`hive:nightly-ranger`** in CI vs init-container plugin extract on every pod start.
3. **Usersync** — Map **`hive` / `admin`** KDC principals to Ranger users for Hue tests.
4. **Solr audit** — Skip in lab (current **`audit_store=db`**) unless you need full audit UI.

## References

- [Apache Ranger Docker dev support](https://github.com/apache/ranger/tree/master/dev-support/ranger-docker)
- [Ranger Hive plugin on Kubernetes (example)](https://fatihmete.github.io/big-data-on-kubernetes/ranger-hive-plugin/)
- [Hive testbench](https://github.com/hortonworks/hive-testbench) — pending; needs disk + Phase 2 for meaningful policy tests
