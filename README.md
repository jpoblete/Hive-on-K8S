# Apache Hive Kubernetes Lab

## Author

José Martínez-Poblete  
j.martinez.poblete@gmail.com

## Usage Notice

This project is not meant for commercial use without permission and proper credit.

Author: j.martinez.poblete@gmail.com

The same two-line header appears at the top of every source file in this repository (shell scripts, YAML manifests, XML config, and `kind` templates):

```text
# Usage Notice: This project is not meant for commercial use without permission and proper credit.
# Author: j.martinez.poblete@gmail.com
```

This project runs Apache Hive on Kubernetes using upstream/minimal container images from Docker Hub (`apache/hive`). Image tags differ by profile; see **Images by profile** below.

The manifests intentionally complete the images at pod startup by installing small OS packages and writing runtime configuration from ConfigMaps. Because those images are minimal, the startup scripts use `root` for bootstrap work and then run Hive/Hadoop services as their application users.

## Contents

Read **Profiles** in order (simplest first). UIs and kind setup are grouped under **[Browser UIs & kind](#browser-uis-and-kind-llap--secure)**.

- [Images by profile](#images-by-profile)
- [Prerequisites](#prerequisites) · [Hardware](#hardware-requirements)
- [**Profiles**](#profiles) — `standalone` → `mini` → `llap` → `secure`
- [Browser UIs & kind (`llap` / `secure`)](#browser-uis-and-kind-llap--secure)
- [Data safety](#data-safety) · [Bootstrap model](#bootstrap-model) · [Lab OS users](#lab-os-users-supergroup)
- [Smoke tests](#smoke-tests) · [Validation](#validation)

## Images by profile

```text
standalone:   apache/hive:4.2.0   (embedded Metastore + HiveServer2 in one pod)
mini:         apache/hive:4.2.0   (Hive Metastore + HiveServer2)
              apache/hadoop:3.4.1 (single-node HDFS in one pod)
llap:         apache/hive:nightly (Hive Metastore x2, HiveServer2 x2, LLAP daemon x2)
              apache/hadoop:3.4.1, gethue/hue:latest
secure:       apache/hive:nightly (same LLAP stack as llap: Metastore x2, HiveServer2 x2, LLAP daemon x2)
              apache/hadoop:3.4.1 (NameNode + 3 DataNodes; Kerberos HDFS)
              debian:bookworm-slim (MIT KDC in krb5kdc-0)
              gethue/hue:latest (Hue → HS2 with SASL/Kerberos backend)
```

`mini` and `standalone` pin the released **4.2.0** image. **`llap` and `secure` use the moving `nightly` tag** (Beeline reports **4.3.0-SNAPSHOT** today) so Tez and LLAP pick up fixes not in 4.2.0—notably [HIVE-29566](https://issues.apache.org/jira/browse/HIVE-29566), where reopening a Tez session in the same HiveServer2 JVM could fail with `JvmMetrics already exists` on grouped/aggregating queries. After an image bump, metastore pods run `schematool` on startup if the schema version changed. Leave headroom on kind or Docker Desktop nodes when pulling `nightly` (~1.5 GiB per node that schedules a Hive pod). To pin `llap` / `secure` to a release tag again, change the image patch in each profile’s `hivemetastore`, `hiveserver2`, and `llapdaemon` kustomizations.

## Prerequisites

Install these tools on the machine where you run `hiveCtl.sh`:

```text
kubectl
kustomize
shellcheck   # optional, for validation
```

You also need a local Kubernetes cluster, for example:

```text
Docker Desktop Kubernetes
kind
minikube
```

## Hardware Requirements

The manifests define resource requests and limits for local Kubernetes labs. The sizes below assume **one profile (overlay) running at a time** — do not start `standalone`, `mini`, `llap`, and `secure` together on the same cluster. Each profile uses its own namespace and PVCs, but they still compete for **the same Docker Desktop / kind VM memory and disk** (duplicate **~1.5 GiB** `apache/hive` / **~1.2 GiB** `apache/hadoop` pulls per node, plus PVCs). Stop other profiles first: `./hiveCtl.sh stop <other>` (PVCs are kept). For **`llap`** and **`secure`**, treat **one active overlay** as required on a **~36 GB RAM** host with default Docker disk.

For the `mini` profile, a cluster with **3 worker nodes** is suggested so Hadoop, MySQL, Metastore, and HiveServer2 have room to schedule cleanly across the local cluster.

Minimum practical host sizes (**one profile active**):

```text
standalone only:
  host RAM:        12 GB+
  Kubernetes RAM:  6 GB+
  CPUs:            2+
  disk:            10 GB+

mini only:
  host RAM:        16 GB+
  Kubernetes RAM:  10-12 GB+
  CPUs:            4+
  disk:            20 GB+

llap only:
  host RAM:        32 GB+
  Kubernetes RAM:  20-24 GB+
  CPUs:            6+
  disk:            30 GB+
  worker nodes:    2+ (one LLAP daemon per node)

secure only:
  host RAM:        36 GB+
  Kubernetes RAM:  26-30 GB+
  CPUs:            8+
  disk:            50 GB+ host Docker VM (see below; PVCs alone are ~51 Gi on secure)
  worker nodes:    3+ for DataNodes; 2+ labeled llap (same as llap profile) for LLAP daemons
```

**`secure`** is **`llap` + Kerberos** (same ZooKeeper, **2×** Metastore / HiveServer2 / LLAP daemon, and Hue; HDFS **1 NN + 3 DN**; realm **`SECURE.LAB`**). Only **`llap`** *or* **`secure`** should be up on a lab sized for the rows above — not both.

With kind on Docker Desktop, every node is a container in the **same** VM: **`df` on each node reflects one shared virtual disk**, not six independent disks. Adding workers spreads pods; it does not add RAM or disk. Give Docker Desktop **enough memory** for the profile and **≥100 GiB disk** if you run **`llap`** or **`secure`** with **`apache/hive:nightly`**. Before large starts: `./hiveCtl.sh disk` (auto-prunes unused images when **`/var`** is above **90%**).

Container limits are above JVM heap (overhead + native memory): Hive **3 Gi**, Hadoop **6 Gi**, MySQL **2 Gi**, LLAP daemon **5 Gi**, ZooKeeper **512 Mi**, Hue **2 Gi**.

## hiveCtl quick reference

Kubernetes **namespace = profile name** (`standalone`, `mini`, `llap`, `secure`). Run **one profile at a time** on a local lab ([Hardware](#hardware-requirements)).

| Action | Command |
|--------|---------|
| Start / stop | `./hiveCtl.sh start <profile>` · `./hiveCtl.sh stop <profile>` |
| One component | `./hiveCtl.sh start <profile> <component>` (e.g. `hue`, `llapdaemon`, `hadoop-namenode`) |
| Status | `./hiveCtl.sh status` · `kubectl get pods,pvc,svc -n <profile>` |
| Backup / restore / cleanup | `./hiveCtl.sh backup|restore|cleanup <profile> [backup-dir]` |

**Hive CLI:** `kubectl exec -it hiveserver2-0 -n <profile> -- su - hive` → `beeline`, `createTable.sh man managed_3_1 3 1 10 1`. **Standalone:** `hive-0` container `hiveserver2`. Details: [Smoke tests](#smoke-tests).

## Profiles

Profiles are documented **simplest first**, each step adding services and operational complexity:

```text
standalone  →  mini  →  llap  →  secure
  Derby          HDFS+MySQL     ZK; 2 HMS/HS2/LLAP  same Hive tier +
  one pod        1 MS, 1 HS2    + Hue               KDC, Kerberos HDFS
```

### `standalone`

| | |
|--|--|
| **Adds** | One pod: embedded Metastore + HiveServer2, Derby, local PVC warehouse |
| **Overlay** | `overlays/standalone/hive` |
| **Start / stop** | `./hiveCtl.sh start standalone` · `./hiveCtl.sh stop standalone` |
| **Try it** | [Smoke tests → standalone](#smoke-tests) |

### `mini`

| | |
|--|--|
| **Adds** | HDFS (one Hadoop pod), MySQL, Hive Metastore, HiveServer2 |
| **Stack** | `hadoop → mysql → hivemetastore → hiveserver2` |
| **Overlays** | `overlays/mini/*` |
| **Start / stop** | `./hiveCtl.sh start mini` · `./hiveCtl.sh stop mini` |
| **HDFS** | `kubectl exec hadoop-0 -n mini -- hdfs dfs -ls /` |
| **Try it** | [Smoke tests → mini](#smoke-tests) |

### `llap`

| | |
|--|--|
| **Adds (on top of `mini`)** | ZooKeeper, **2×** Hive Metastore & HiveServer2, **2×** LLAP daemons, Hue |
| **Image** | `apache/hive:nightly` (Tez/LLAP fixes; see [Images by profile](#images-by-profile)) |
| **Hive tier** | **2** Metastore · **2** HiveServer2 · **2** LLAP daemons (StatefulSets, `replicas: 2`) |
| **Stack** | `hadoop → mysql → zookeeper → hivemetastore×2 → llapdaemon×2 → hiveserver2×2 → hue` |
| **Overlays** | `overlays/llap/*` — shared `hive-site.xml` in `llap/hivemetastore` |
| **Prerequisite** | Label **two** workers `node-role.kubernetes.io/llap` or use [`kind/llap-cluster.yaml`](kind/llap-cluster.yaml) ([details](#browser-uis-and-kind-llap--secure)) |
| **Start / stop** | `./hiveCtl.sh start llap` · `./hiveCtl.sh stop llap` |
| **UIs** | Hue **http://localhost:8888** · LLAP **http://localhost:15002** ([Browser UIs](#browser-uis-and-kind-llap--secure)) |
| **Query path** | Tez AM in HiveServer2 (**local mode**, no YARN) → fragments on `@llap0` daemons; Beeline via ZK (`BEELINE_URL` in pods) |
| **Logs on HDFS** | `hdfs://nameservice:8020/user/hive/logs/llap/…` — `tez/application_*`, `llap/application_*`, stable `*.log` ([`samples/logging/`](samples/logging/README.md)) |
| **Try it** | [Smoke tests → llap](#smoke-tests) |

### `secure`

| | |
|--|--|
| **Adds (on top of `llap`-shaped Hive)** | MIT KDC, Kerberos HDFS (**1 NN + 3 DN**, `dfs.replication=3`); same **ZooKeeper, LLAP×2, Hue, 2×** Metastore & HiveServer2 as **`llap`**, all with Kerberos |
| **Image** | `apache/hive:nightly` (see [Images by profile](#images-by-profile)) |
| **Hive tier** | **2** Metastore · **2** HiveServer2 · **2** LLAP daemons (same as **`llap`**, Kerberos-enabled) |
| **Stack** | `krb5kdc → hadoop-namenode (+ 3× datanode) → mysql → zookeeper → hivemetastore×2 → llapdaemon×2 → hiveserver2×2 → hue` |
| **Prerequisite** | **Three** workers for DataNodes; **two** workers labeled **`node-role.kubernetes.io/llap`** (or [`kind/llap-cluster.yaml`](kind/llap-cluster.yaml) with enough nodes) |
| **Query path** | Same as **`llap`**: Tez AM in HiveServer2 (**local mode**) → fragments on **`@llap0`**; Beeline via ZK after **`kinit`** (`BEELINE_URL` in HS2 pods) |
| **Components** | `components/krb5kdc`, `hadoop-namenode`, `hadoop-datanode` · `overlays/secure/*` |
| **Start / stop** | `./hiveCtl.sh start secure` (KDC → Hadoop → …; first start waits for **3 DNs**) · `./hiveCtl.sh stop secure` |
| **Shells** | `hadoop-namenode-0`, `hiveserver2-0` (`su - hive`) |
| **UIs** | Hue **http://localhost:8888** · LLAP **http://localhost:15002** ([Browser UIs](#browser-uis-and-kind-llap--secure)) |
| **Logs on HDFS** | `hdfs://nameservice:8020/user/hive/logs/secure/…` — **`tez/`** and **`llap/`** query exports ([`samples/logging/`](samples/logging/README.md)) |
| **Try it** | [Smoke tests → secure](#smoke-tests) |

**Kerberos (summary):** realm **`SECURE.LAB`**, KDC pod **`krb5kdc-0`**, keytabs in Secret **`kerberos-keytabs`** (synced by `hiveCtl` from KDC PVC). Host principals **`hdfs/`**, **`hive/`**, **`hue/`** + FQDN; Tez local mode needs short-name principals (e.g. **`hive/hiveserver2-0@…`**). Resync after KDC changes: **`HIVECTL_KRB5_RESYNC_KEYTABS=1 ./hiveCtl.sh start secure`**.

**HDFS:** Kerberos auth + **`dfs.data.transfer.protection=authentication`** on NN/DN; admin/backup via **`hadoop-namenode-0`** (not `hadoop-0`). Do not enable **`dfs.encrypt.data.transfer`** on the NameNode alone.

**Hive:** Metastore SASL, **`hive.server2.authentication=KERBEROS`**, **`tez.local.mode=true`**, LLAP execution (**`hive.execution.mode=llap`**). Beeline: **`kinit`** then **`beeline -u "${BEELINE_URL}"`** inside an HS2 pod (ZK discovery + Kerberos).

**Hue:** **`use_sasl=true`** to HS2; File Browser WebHDFS to **`nameservice:9870`** as **`hue/…`**. Literal HS2 principal in `hue-hive-conf/hive-site.xml` (not `hive/_HOST`).

<a id="secure-hue"></a>

## Browser UIs and kind (`llap` / `secure`)

Both profiles ship **[Hue](https://gethue.com/)** (`gethue/hue:latest`). **`llap`**: JDBC user **`hive`** / **`beeline-password`**. **`secure`**: browser login stays Hue-local; HS2 uses Kerberos ([secure Hue](#secure-hue)).

| UI | URL (typical) | `hiveCtl` |
|----|---------------|-----------|
| Hue | **http://localhost:8888** | Auto port-forward after start (or kind NodePort **30888** / **30889**) |
| LLAP daemon (`llap` / `secure`) | **http://localhost:15002** | Forwards **`llapdaemon-0`** after start |

```bash
./hiveCtl.sh start llap    # or: start secure
# Manual if needed:
kubectl port-forward svc/hue -n llap 8888:8888
kubectl port-forward pod/llapdaemon-0 -n llap 15002:15002
```

| Env | Default | Purpose |
|-----|---------|---------|
| `HIVECTL_HUE_PORT_FORWARD` | `auto` | `0` = no Hue port-forward |
| `HIVECTL_HUE_LOCAL_PORT` | `8888` | Local Hue port |
| `HIVECTL_LLAP_DAEMON_LOCAL_PORT` | `15002` | Local LLAP UI port |

**kind for `llap` / `secure`:** LLAP daemons need **two** workers labeled **`node-role.kubernetes.io/llap`**. Recommended: **`kind create cluster --config kind/llap-cluster.yaml`** (labels **`desktop-worker4`** / **`desktop-worker5`**, maps **8888** for Hue). **`secure`** also needs **three** schedulable workers for DataNode PVCs. Otherwise: `kubectl label node <worker4> <worker5> node-role.kubernetes.io/llap=` before start.

## Data safety

### Kind disk space (`ImagePullBackOff`)

Applies to **`standalone`**, **`mini`**, **`llap`**, and **`secure`** on Kind/Docker Desktop: large images (**`apache/hive`**, **`apache/hadoop`**, **`gethue/hue`**) can fill node **`/var`** and cause **`no space left on device`** on **`ImagePullBackOff`**.

**`hiveCtl.sh`** checks each cluster node’s Kind container before **`start`**, **`restore`**, and **`backup`** (once per invocation) and runs **`crictl rmi --prune`** when **`/var`** use exceeds **90%** (**`HIVECTL_DISK_MAX_USE_PERCENT`**, disable with **`HIVECTL_DISK_CHECK=0`**).

```bash
./hiveCtl.sh disk    # print /var use per node and prune if needed
```

If a node stays above **~98%**, increase Docker Desktop disk or run **`docker system prune -f`** on the host, then delete stuck pods.

PVCs hold the persistent data. Deleting PVCs can cause data loss.

`hiveCtl.sh` creates namespace-local Kubernetes Secrets at startup instead of storing passwords in Git. Backups include a portable copy of those generated credentials:

```text
hive-credentials.secret.json
```

Typical keys in Secret **`hive-credentials`** (namespace = profile name):

| Key | Used for |
|-----|----------|
| `root-password` | `root` in Hive/Hadoop pods (bootstrap only) |
| `hive-password` | Unix `hive`, SSH between Hive pods |
| `hadoop-password` | Unix `hadoop` in the Hadoop pod |
| `beeline-password` | Beeline / JDBC user **`hive`** |
| `hive-metastore-password` | MySQL user for the Hive metastore schema |
| `mysql-root-password` | MySQL `root` |
| `admin-password` | Documented copy of the fixed lab **`admin`** password (always **`admin`**) |
| `hue-mysql-password`, `hue-secret-key` | **`llap`** and **`secure`** Hue |
| `krb5-master-password`, `krb5-kadmin-password` | **`secure`** MIT KDC only |

Treat backup directories as sensitive because they contain both data and credentials.

`stop` keeps the PVCs and gives each pod its grace period to shut its services down cleanly. When the Kubernetes API can't be reached, `hiveCtl.sh` reports the error and stops rather than treating components as stopped or missing.

Use backup before cleanup:

```bash
./hiveCtl.sh backup standalone
./hiveCtl.sh backup mini
./hiveCtl.sh backup llap
./hiveCtl.sh backup secure
```

Restore:

```bash
./hiveCtl.sh restore standalone <backup-dir>
./hiveCtl.sh restore mini <backup-dir>
./hiveCtl.sh restore llap <backup-dir>
./hiveCtl.sh restore secure <backup-dir>
```

Restore also works after cleanup or on a new cluster: it creates the namespace with the backed-up credentials, starts the storage, loads the backup, and then starts the rest of the stack. If MySQL already has a volume, the current credentials are kept, because MySQL created its users with them and the metastore dump doesn't include users.

Destructive cleanup requires confirmation and offers to create a backup first:

```bash
./hiveCtl.sh cleanup standalone
./hiveCtl.sh cleanup mini
./hiveCtl.sh cleanup llap
./hiveCtl.sh cleanup secure
```

## Bootstrap model

The startup scripts use `root` to:

- install missing packages with retry logic (Hadoop installs its tools in the background and keeps the RPMs on its volume under `/hdfs/rpm-cache`, so only the first start of a new volume needs the CentOS mirrors)
- copy mounted ConfigMap files into Hive/Hadoop config directories
- prepare users, permissions, SSH, and symlinks
- ensure Unix group **`supergroup`**, add **`hive`** to it, and create OS user **`admin`** (also in **`supergroup`**) with fixed lab password **`admin`** — see **[Lab OS users](#lab-os-users-supergroup)**

The long-running services then run as:

- `hadoop` for Hadoop (**`mini`** / **`llap`**: one pod; **`secure`**: NameNode and DataNode pods)
- `hive` for Hive Metastore, HiveServer2, and the LLAP daemons
- `zookeeper` for ZooKeeper (`llap` and `secure`; the image drops privileges itself)
- `root`-installed scripts on **`krb5kdc-0`** then KDC daemons as packaged by Debian (`secure` only)

This keeps the upstream images unchanged while still making the lab reproducible.

The Hadoop container restarts itself when HDFS stops answering: its liveness probe runs `hdfs dfs -ls -R /` and checks the DataNode port every 30 seconds, and three failures in a row restart it. The daemon logs live on the Hadoop volume under `/hdfs/logs`, so they survive the restart for a post mortem:

```bash
kubectl exec hadoop-0 -n mini -- ls -l /hdfs/logs
kubectl exec hadoop-namenode-0 -n secure -- ls -l /hdfs/logs
```

Deleting the Hadoop pod stops the HDFS daemons cleanly, in reverse start order, instead of waiting out the grace period. On **`secure`**, stop **`hadoop-namenode`** (via **`hiveCtl`**) to tear down NameNode and all DataNodes together. YARN stays configured but isn't started, since HiveServer2 runs Tez itself; to bring it back, add the ResourceManager and NodeManager to the daemon list in `components/hadoop/configmap.yaml` (**`mini`** / **`llap`** only).

## Lab OS users (`supergroup`)

Hadoop treats members of Unix group **`supergroup`** like a superuser group for HDFS (similar to a default **`hdfs`** admin group). This lab creates **`supergroup`** at pod bootstrap and puts both service and break-glass users in it.

| Unix user | Password (this exercise) | Group(s) | Where created | Runs long-lived service? |
|-----------|---------------------------|----------|---------------|---------------------------|
| **`hive`** | `hive-password` in Secret (random; **`hive`** on legacy **mini** PVC) | **`supergroup`**, `hive` | Hive + Hadoop bootstrap | Yes — Metastore, HS2, LLAP |
| **`admin`** | **`admin`** (fixed; also stored as `admin-password` in Secret) | **`supergroup`**, `admin` | Hive + Hadoop bootstrap | No — interactive / debugging |
| **`hadoop`** | `hadoop-password` in Secret | (image default) | Hadoop bootstrap | Yes — HDFS daemons |
| **`root`** | `root-password` in Secret | — | bootstrap only | No — installs packages, then services drop privileges |

**Not for production** — fixed **`admin`/`admin`** is intentional for local labs only.

On **`mini`** / **`llap`**, first HDFS format (Hadoop pod) creates **`/users/admin`** owned **`admin:supergroup`**, alongside **`/users/hive`** and warehouse paths owned **`hive:supergroup`**. On **`secure`**, the same layout is created under **`/user/...`** and **`/warehouse/...`** when the NameNode formats (after three DataNodes register).

Log in as **`admin`** inside a Hive pod:

```bash
kubectl exec -it hiveserver2-0 -n llap -- su - admin
# password: admin
id    # should list supergroup
```

Same on **`hadoop-0`** (**`mini`** / **`llap`**) or **`hadoop-namenode-0`** (**`secure`**) for HDFS CLI as **`admin`** (Kerberos **`kinit`** as **`hdfs/...`** on **`secure`** before **`hdfs dfs`**):

```bash
kubectl exec -it hadoop-0 -n llap -- su - admin
hdfs dfs -ls /
kubectl exec -it hadoop-namenode-0 -n secure -- bash -lc 'sudo -u hadoop kinit -kt /home/hadoop/host-service.keytab "hdfs/$(hostname -f)@SECURE.LAB"; sudo -u admin hdfs dfs -ls /'
```

After upgrading manifests, **restart** Hive/Hadoop pods (or `./hiveCtl.sh restart <profile> <component>`) so **`staging.sh`** / **`root-tasks.sh`** recreate group membership. Existing clusters get **`admin-password`** patched to **`admin`** on the next `./hiveCtl.sh start`.

Implementation: **`ensureSupergroupLabUsers`** in `base/configmap.yaml` (Hive), matching logic in `components/hadoop/configmap.yaml` (**`mini`** / **`llap`**), `components/hadoop-namenode/configmap.yaml` and `components/hadoop-datanode/configmap.yaml` (**`secure`**), and `overlays/standalone/hive/configmap.yaml`.

## Smoke tests

Standalone Beeline:

```bash
kubectl exec hive-0 -c hiveserver2 -n standalone -it -- /bin/bash
su - hive
beeline -e "show databases;"
```

Mini HDFS:

```bash
kubectl exec hadoop-0 -n mini -- hdfs dfs -ls /
```

Mini Beeline:

```bash
kubectl exec hiveserver2-0 -n mini -it -- /bin/bash
su - hive
beeline -e "show databases;"
```

LLAP HDFS:

```bash
kubectl exec hadoop-0 -n llap -- hdfs dfs -ls /
```

LLAP ZooKeeper (HiveServer2 and LLAP worker registration):

```bash
kubectl exec zookeeper-0 -n llap -- zkCli.sh ls /hiveserver2
kubectl exec zookeeper-0 -n llap -- zkCli.sh ls /llap-unsecure/user-hive/llap0/workers
```

LLAP Beeline (ZooKeeper service discovery; `BEELINE_URL` is set inside Hive pods):

```bash
kubectl exec hiveserver2-0 -n llap -it -- /bin/bash
su - hive
beeline -e "show databases;"
beeline -e "select count(*) from managed_3_1;"
```

LLAP **`admin`** OS user (`admin` / `admin`, **`supergroup`**):

```bash
kubectl exec hiveserver2-0 -n llap -it -- su - admin -c 'id && hdfs dfs -ls /users 2>/dev/null || true'
```

LLAP Hue — [Browser UIs](#browser-uis-and-kind-llap--secure):

```bash
kubectl get pods,svc -n llap -l app=hue
kubectl wait --for=condition=ready pod -l app=hue -n llap --timeout=300s
# → http://localhost:8888 (kind template or port-forward)
```

LLAP daemon UI — [Browser UIs](#browser-uis-and-kind-llap--secure):

```bash
kubectl get pods -n llap -l app=llapdaemon
kubectl wait --for=condition=ready pod/llapdaemon-0 -n llap --timeout=300s
# → http://localhost:15002 (hiveCtl port-forward after start llap llapdaemon)
curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:15002/
```

Secure KDC and HDFS (Kerberos):

```bash
kubectl get pods -n secure -l app=krb5kdc
kubectl exec krb5kdc-0 -n secure -- kadmin.local -q 'list_principals' | head
kubectl exec hadoop-namenode-0 -n secure -- bash -lc \
  'sudo -u hadoop kinit -kt /home/hadoop/host-service.keytab "hdfs/$(hostname -f)@SECURE.LAB"; hdfs dfs -ls /'
kubectl get pods -n secure -l app=hadoop-datanode
```

Secure Beeline (Kerberos JDBC; use an interactive shell or **`script -qefc '...' /dev/null`** under **`kubectl exec`**):

```bash
kubectl exec -it hiveserver2-0 -n secure -- su - hive
beeline -u "${BEELINE_URL}" -e "select 1;"
beeline -u "${BEELINE_URL}" -e "show databases;"
```

Secure backup / restore smoke (destructive **`cleanup`** prompts for confirmation):

```bash
./hiveCtl.sh backup secure
./hiveCtl.sh cleanup secure    # offers backup; type profile name to confirm
./hiveCtl.sh restore secure ./backups/secure-YYYYMMDD-HHMMSS
```

Secure Hue — [Browser UIs](#browser-uis-and-kind-llap--secure):

```bash
kubectl get pods,svc -n secure -l app=hue
kubectl wait --for=condition=ready pod/hue-0 -n secure --timeout=300s
curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:8888/
```

## Validation

Render all overlays:

```bash
for d in overlays/standalone/hive \
         overlays/mini/hadoop overlays/mini/mysql overlays/mini/hivemetastore overlays/mini/hiveserver2 \
         overlays/llap/hadoop overlays/llap/mysql overlays/llap/zookeeper overlays/llap/hivemetastore overlays/llap/llapdaemon overlays/llap/hiveserver2 overlays/llap/hue \
         overlays/secure/krb5kdc overlays/secure/hadoop-namenode overlays/secure/hadoop-datanode overlays/secure/mysql \
         overlays/secure/zookeeper overlays/secure/hivemetastore overlays/secure/llapdaemon overlays/secure/hiveserver2 overlays/secure/hue; do
  kustomize build "$d" --load-restrictor LoadRestrictionsNone | kubectl apply --dry-run=client -f -
done
```

Lint the controller script:

```bash
shellcheck hiveCtl.sh
```
