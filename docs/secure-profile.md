# Secure profile (`overlays/secure`)

Deep reference for **`secure`**: **`llap`-shaped Hive (2× Metastore, 2× HiveServer2, 2× LLAP)** plus **Kerberos HDFS**, **MIT KDC**, and **Kerberos ZooKeeper**. Namespace: **`secure`**. Realm: **`SECURE.LAB`**.

For day-to-day commands, see [README.md](../README.md) (profiles, `hiveCtl`, smoke tests).

## How `secure` differs from `llap`

| Area | `llap` | `secure` |
|------|--------|----------|
| HDFS | Single Hadoop pod | **1 NameNode + 3 DataNodes**, Kerberos, `dfs.replication=3` |
| ZooKeeper | Plain TCP | **SASL/Kerberos** (`overlays/secure/zookeeper/`) |
| Hive auth | JDBC password | **Kerberos** (Metastore SASL, HS2 `KERBEROS`) |
| ZK connect strings | `zookeeper.llap.svc.cluster.local:2181` | **`zookeeper-0.zookeeper.secure.svc.cluster.local:2181`** (pod FQDN) |
| HS2 `hive.user.install.directory` | Shared `/opt/hive/install_dir` | **Per pod** `/opt/hive/install_dir/${POD_NAME}` |
| Tez session at HS2 startup | `hive.server2.tez.initialize.default.sessions=true` | **`true`** (same as **`llap`**; required for LLAP scheduler metrics + Tez local Kerberos IPC) |
| Keytabs | N/A | Secret **`kerberos-keytabs`**, synced from KDC PVC via **`hiveCtl`** |

Stack order: **`krb5kdc → hadoop-namenode (+ 3× datanode) → mysql → zookeeper → hivemetastore×2 → llapdaemon×2 → hiveserver2×2 → hue`**.

## Kerberos ZooKeeper

LLAP on **Hive 4.3** (`apache/hive:nightly`) uses a ZooKeeper-backed delegation-token secret manager for LLAP with **`zkAuthType=sasl`**. Plain ZooKeeper (as in **`llap`**) is not sufficient for secure LLAP daemons.

**Manifests:**

- `overlays/secure/zookeeper/kerberos-statefulset.yaml` — SASL, JAAS, keytab mount, `setHostnameAsFQDN`
- `overlays/secure/zookeeper/jaas.conf` — `Server { … }` for **`zookeeper/…@SECURE.LAB`**
- `components/krb5kdc/configmap.yaml` — **`secure-lab-hosts.list`** includes **`zookeeper-0.zookeeper.secure.svc.cluster.local|zookeeper|zookeeper-0`**

**Client settings (all Hive components in `secure`):**

- `hive.zookeeper.quorum`, `hive.llap.zk.sm.connectionString`, `hive.cluster.delegation.token.store.zookeeper.connectString` → **`zookeeper-0.zookeeper.secure.svc.cluster.local:2181`**
- Do **not** set `hive.llap.zk.sm.principal` / `hive.llap.zk.sm.keytab.file` in overlay; Hive configures SASL for the LLAP ZK SM internally.
- LLAP JVM (Kerberos): **`LLAP_DAEMON_OPTS`** includes **`-Djavax.security.auth.useSubjectCredsOnly=false`** when **`HIVE_KERBEROS=1`** (`base/configmap.yaml`).

**Operations:**

```bash
./hiveCtl.sh resync-keytabs secure    # refresh Secret after KDC host list changes
./hiveCtl.sh restart secure zookeeper
```

## Tez local mode and LLAP queries

- **`tez.local.mode=true`** — Tez AM runs inside HiveServer2 (no YARN in this lab).
- **`hive.execution.mode=llap`**, **`hive.llap.daemon.service.hosts=@llap0`**
- **`mapreduce.job.hdfs-servers=hdfs://nameservice`** — delegation tokens for Tez on the nameservice.
- **`yarn.resourcemanager.principal`** in HS2 **`core-site.xml`** — set at runtime to the pod’s **`hive/<fqdn>@SECURE.LAB`** so Tez local mode can obtain HDFS tokens without a YARN RM.

HS2 IPC Kerberos uses **host keytabs v3**: each pod keytab includes **FQDN and short StatefulSet name** principals (e.g. **`hive/hiveserver2-0@SECURE.LAB`**).

## Tez sessions at HiveServer2 startup

**`hive.server2.tez.initialize.default.sessions=true`** in `overlays/secure/hiveserver2/hive-site.xml` (same as **`llap`**).

| Setting | `llap` | `secure` |
|---------|--------|----------|
| `hive.server2.tez.initialize.default.sessions` | `true` | **`true`** |

**Why:** In Tez local mode the LLAP task scheduler registers **JvmMetrics** once per HiveServer2 JVM. Opening a **second** Tez session on the same pod (typical when **`false`**) fails with *metrics already initialized* and **`TezSession has already shutdown`**. A **single** session opened at HS2 startup (after **`kinit`** and minimal **`.hiveJars`** seed) matches **`llap`** behavior.

**Kerberos IPC:** **`HADOOP_OPTS`** / **`HADOOP_CLIENT_OPTS`** and **`tez.am.launch.cmd-opts`** set **`-Djavax.security.auth.useSubjectCredsOnly=false`** so the Tez AM RPC client can use the **`hive/<fqdn>`** keytab login user.

## Per-pod install dir and Tez jar cache (`.hiveJars`)

Two HS2 pods must not share one HDFS **`/opt/hive/install_dir/hive/.hiveJars`** (concurrent Tez uploads → **0-byte** or wrong-size JARs → **`PathExists`** / “Previous writer may have failed”).

**Overlay:** `hive.user.install.directory` = **`__HIVE_USER_INSTALL_DIR__`** → substituted at startup to **`/opt/hive/install_dir/${POD_NAME}`** (`base/configmap.yaml` **`start-hive.sh`**):

1. Copy config to **`/opt/hive/conf-runtime`** and rewrite the placeholder.
2. **`cleanCorruptHiveJarCache`** — remove the cache if any **zero-byte** JAR exists (fast). Full **size-mismatch** scan is opt-in: **`HIVE_JAR_CACHE_VALIDATE_MISMATCH=1`** (slow; ~350 HDFS stats).
3. **`seedTezHiveJarsToHdfs`** — uploads Tez/LLAP-related jars ( **`HIVE_TEZ_JAR_SEED=minimal`** on **`secure`**, or **`full`** / **`off`**) with **`dfs.replication=1`**, then **`.seed-complete`**. Seed failure logs a **warning** and HS2 still starts (no CrashLoop from HDFS full). If the marker exists and jar **count** matches, upload is **skipped**.
4. Start HS2 with **`--hiveconf hive.user.install.directory=/opt/hive/install_dir/${POD_NAME}`**.

Requires **`POD_NAME`** in the HS2 StatefulSet (`overlays/secure/hiveserver2/kustomization.yaml`).

**Manual recovery (if queries fail on jar localization):**

```bash
kubectl exec -n secure hiveserver2-0 -- bash -lc '
  kinit -kt /home/hive/host-service.keytab "hive/$(hostname -f)@SECURE.LAB"
  hdfs dfs -rm -r -f /opt/hive/install_dir/hiveserver2-0/hive/.hiveJars
  # re-run startup seed logic or restart the pod after applying latest ConfigMap
'
./hiveCtl.sh restart secure hiveserver2
```

**Beeline + ZooKeeper discovery:** JDBC may hit **`hiveserver2-0`** or **`hiveserver2-1`**. Each pod needs its **own** seeded cache. If only one pod was seeded manually, pin JDBC for debugging:

```bash
export BEELINE_URL='jdbc:hive2://hiveserver2-0.hiveserver2-headless.secure.svc.cluster.local:10000/default;principal=hive/hiveserver2-0.hiveserver2-headless.secure.svc.cluster.local@SECURE.LAB'
```

Production path: restart both HS2 pods after config apply so **both** run **`seedTezHiveJarsToHdfs`**.

## Disk space (Kind / Docker Desktop)

**Symptom:** **`/var` ~100%** on Kind nodes → partial HDFS writes, **`ImagePullBackOff`**, failed Tez JAR uploads.

**Automatic (per node, unused container images only):**

```bash
./hiveCtl.sh disk
```

**When nodes stay above ~98%:**

1. Increase **Docker Desktop → Settings → Resources → Disk** (recommend **≥100 GiB** for **`secure`** + **`nightly`** images).
2. On the host (removes **unused** images/volumes — review first):

   ```bash
   docker system df
   docker image prune -a -f    # aggressive: unused images cluster-wide
   docker volume prune -f      # only if you accept reclaiming unused volumes
   ```

3. Per Kind node:

   ```bash
   for n in desktop-control-plane desktop-worker desktop-worker2 desktop-worker3 desktop-worker4 desktop-worker5; do
     docker exec "$n" crictl rmi --prune
     docker exec "$n" df -h /var
   done
   ```

4. Regenerable HDFS paths (optional, saves NN/DN PVC pressure): Tez scratch **`/opt/hive/scratch_dir/hive/_tez_session_dir`**, stale **`.hiveJars`** under **`/opt/hive/install_dir/`** (see jar section).

Run **one profile at a time** on a constrained host ([README hardware](../README.md#hardware-requirements)).

## Smoke tests

From **`hiveserver2-0`** (interactive or **`script -qefc '…' /dev/null`** under **`kubectl exec`**):

```bash
kubectl exec -it hiveserver2-0 -n secure -- su - hive
kinit -kt /home/hive/host-service.keytab "hive/$(hostname -f)@SECURE.LAB"
cd /opt/hive/setup
./createTable.sh man managed_3_1 3 1 10 1
beeline -u "${BEELINE_URL}" -e "select c1, count(*) from managed_3_1 group by c1 order by c1;"
```

**Expected when healthy:** DROP/CREATE/INSERT complete; GROUP BY returns counts per **`c1`**.

**Common failures:**

| Error | Likely cause |
|-------|----------------|
| `Could not find jar … localize … Previous writer may have failed` | Bad **`.hiveJars`** on the HS2 instance that served the query; disk full; seed not run on that pod |
| `AuthFailed` / ZK **`InvalidACL`** on `/zkdtsm_hive_llap0` | ZK not Kerberized or wrong connect string |
| `TezSession has already shutdown` | HS2 restarted mid-query; retry in interactive shell |
| Beeline connects to **`hiveserver2-1`** but only **`hiveserver2-0`** seeded | Restart both HS2 or pin **`BEELINE_URL`** (above) |

## Keytabs and KDC

```bash
./hiveCtl.sh resync-keytabs secure
kubectl exec krb5kdc-0 -n secure -- kadmin.local -q 'list_principals' | head
```

After adding hosts to **`secure-lab-hosts.list`**, resync and restart affected pods.

## Overlay file map

```text
overlays/secure/
  krb5kdc/           MIT KDC
  hadoop-namenode/   Kerberos NN
  hadoop-datanode/   3× DN
  mysql/
  zookeeper/         Kerberos SASL ZK (jaas.conf, kerberos-statefulset.yaml)
  hivemetastore/     shared hive-site.xml source for HMS / HS2 / LLAP configmaps
  llapdaemon/
  hiveserver2/       BEELINE_URL (ZK), POD_NAME, kerberos mounts
  hue/
```

Shared bootstrap: **`base/configmap.yaml`** (`staging.sh`, **`start-hive.sh`**, **`hive-env.sh`**).

## Verification status (lab)

| Check | Notes |
|-------|--------|
| 2× HMS / HS2 / LLAP Ready | Achieved with Kerberos ZK |
| LLAP daemons stable | After ZK SASL + LLAP JVM Kerberos opts |
| **`createTable.sh` / GROUP BY** | Requires healthy **`.hiveJars`** on **both** HS2 pods and adequate disk; re-verify after **`./hiveCtl.sh restart secure hiveserver2`** |

## Related

- [README — Profiles](../README.md#profiles)
- [README — Kind disk](../README.md#kind-disk-space-imagepullbackoff)
- [README — Smoke tests](../README.md#smoke-tests)
