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

- [Images by profile](#images-by-profile)
- [**Access Hue (llap / secure)**](#access-hue-llap--secure-profiles) — **http://localhost:8888**
- [**Access LLAP daemon UI (llap)**](#access-llap-daemon-ui-llap-profile) — **http://localhost:15002**
- [KIND cluster for `llap`](#kind-cluster-for-llap)
- [Profiles](#profiles) — `standalone` → `mini` → [`llap`](#llap) → [`secure`](#secure)
- [Data Safety](#data-safety) (includes [Kind disk / prune](#kind-disk-space-imagepullbackoff))
- [Lab OS users (`supergroup`)](#lab-os-users-supergroup)
- [Smoke Tests](#smoke-tests)

## Images by profile

```text
standalone:   apache/hive:4.2.0   (embedded Metastore + HiveServer2 in one pod)
mini:         apache/hive:4.2.0   (Hive Metastore + HiveServer2)
              apache/hadoop:3.4.1 (single-node HDFS in one pod)
llap:         apache/hive:nightly (Hive Metastore x2, HiveServer2 x2, LLAP daemon x2)
              apache/hadoop:3.4.1, gethue/hue:latest (Hue → Access Hue)
secure:       apache/hive:4.2.0   (Hive Metastore x2, HiveServer2 x2)
              apache/hadoop:3.4.1 (NameNode + 3 DataNodes; Kerberos HDFS)
              debian:bookworm-slim (MIT KDC in krb5kdc-0)
              gethue/hue:latest (Hue → HS2 with SASL/Kerberos backend)
```

`mini` and `standalone` pin the released **4.2.0** image. **`llap` uses the moving `nightly` tag** (Beeline reports **4.3.0-SNAPSHOT** today) so Tez and LLAP pick up fixes not in 4.2.0—notably [HIVE-29566](https://issues.apache.org/jira/browse/HIVE-29566), where reopening a Tez session in the same HiveServer2 JVM could fail with `JvmMetrics already exists` on grouped/aggregating queries. After an image bump, metastore pods run `schematool` on startup if the schema version changed. Leave headroom on kind or Docker Desktop nodes when pulling `nightly` (~1.5 GiB per node that schedules a Hive pod). To pin `llap` to a release tag again, change the image patch in `overlays/llap/hivemetastore/kustomization.yaml`, `overlays/llap/hiveserver2/kustomization.yaml`, and `overlays/llap/llapdaemon/kustomization.yaml`.

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

## Access Hue (llap / secure profiles)

The **`llap`** and **`secure`** profiles include **[Hue](https://gethue.com/)** (`gethue/hue:latest`) for browser-based SQL. **`llap`** connects to HiveServer2 with JDBC user/password; **`secure`** keeps the Hue **web UI** as local login but uses **Kerberos (SASL)** from Hue to HiveServer2 (see **[`secure` → Hue](#secure-hue)**).

### Default: open **http://localhost:8888** after start

```bash
./hiveCtl.sh start llap    # or: ./hiveCtl.sh start secure
# When Hue is Ready, hiveCtl prints: Hue UI: http://localhost:8888/ ...
```

**`hiveCtl.sh` tries to expose Hue without a second terminal:**

1. Waits for the Hue pod (via normal start rollout).
2. If **http://localhost:8888** already responds (typical with **kind + [`kind/llap-cluster.yaml`](kind/llap-cluster.yaml)**), it **does not** start another listener.
3. Otherwise it runs **`kubectl port-forward svc/hue -n llap 8888:8888`** in the background (pid under **`.hivectl/`**). **`./hiveCtl.sh stop llap`** or **`stop llap hue`** stops that port-forward.

While **`hue-0`** is **Ready**, **`hiveCtl.sh`** runs a background monitor (every **60s** by default) that probes **http://localhost:8888** and restarts **`kubectl port-forward`** if localhost stops responding. Logs: **`.hivectl/hue-portforward-monitor.log`**. Host **8888** without port-forward only works when the cluster was created with **`kind create cluster --config kind/llap-cluster.yaml`** (maps NodePort **30888** on the control-plane node).

| Variable | Default | Meaning |
|----------|---------|---------|
| `HIVECTL_HUE_PORT_FORWARD` | `auto` | Set to **`0`** to never start port-forward (NodePort / kind only) |
| `HIVECTL_HUE_LOCAL_PORT` | `8888` | Local URL port |
| `HIVECTL_HUE_PORT_FORWARD_MONITOR` | `1` | Set to **`0`** to disable the minute-by-minute port-forward watchdog |
| `HIVECTL_HUE_PORT_FORWARD_MONITOR_INTERVAL` | `60` | Seconds between Hue localhost health checks |

Manual port-forward (if auto mode failed or you disabled it):

```bash
kubectl port-forward svc/hue -n llap 8888:8888
```

**NodePort only:**

| Profile | Service | NodePort | Manifest |
|---------|---------|----------|----------|
| **`llap`** | `hue` in namespace `llap` | **30888** | `overlays/llap/hue/service.yaml` |
| **`secure`** | `hue` in namespace `secure` | **30889** | `overlays/secure/hue/service.yaml` |

Try **http://localhost:30888** or **http://localhost:30889** on Docker Desktop, or `http://<node-ip>:<port>`. If both profiles run at once, set **`HIVECTL_HUE_LOCAL_PORT`** to a free port for the second profile’s port-forward.

First visit (**`llap`**): complete Hue’s setup wizard. The SQL editor lists **Hive** only (**Impala** is disabled via `app_blacklist` in `overlays/llap/hue/configmap.yaml`). Hive login uses user **`hive`** and **`beeline-password`** from Secret `hive-credentials`.

More detail: **[`llap` → Hue](#hue-llap-sql-ui)** and **[`secure` → Hue](#secure-hue)**.

## Access LLAP daemon UI (llap profile)

Each **`llapdaemon`** pod exposes a web UI on port **15002** (executors, cache, metrics). This lab runs **two** daemons (`llapdaemon-0`, `llapdaemon-1`); **`hiveCtl.sh` forwards `llapdaemon-0` only** to the host.

### Default: open **http://localhost:15002** after start

```bash
./hiveCtl.sh start llap
# After llapdaemon StatefulSet is Ready, hiveCtl prints: LLAP daemon UI: http://localhost:15002/ ...
```

Or start daemons alone:

```bash
./hiveCtl.sh start llap llapdaemon
```

**Automatic exposure** (same idea as Hue):

1. Rollout waits for **`llapdaemon`** pods to become Ready.
2. If **http://localhost:15002** already responds, **`hiveCtl.sh` does not** start a second listener.
3. Otherwise it runs **`kubectl port-forward pod/llapdaemon-0 -n llap 15002:15002`** in the background (pid under **`.hivectl/llap-daemon-portforward.pid`**). **`./hiveCtl.sh stop llap llapdaemon`** or **`stop llap`** stops it.

| Variable | Default | Meaning |
|----------|---------|---------|
| `HIVECTL_LLAP_DAEMON_PORT_FORWARD` | `auto` | Set to **`0`** to disable auto port-forward |
| `HIVECTL_LLAP_DAEMON_LOCAL_PORT` | `15002` | Local URL port |

Manual port-forward (second daemon or if auto mode failed):

```bash
kubectl port-forward pod/llapdaemon-0 -n llap 15002:15002
kubectl port-forward pod/llapdaemon-1 -n llap 15003:15002   # example: second UI on another local port
```

There is **no** kind `extraPortMappings` entry for **15002** (unlike Hue **8888**); port-forward (or your own NodePort patch) is required unless **`hiveCtl.sh`** starts it for you.

## Hardware Requirements

The manifests define resource requests and limits for local Kubernetes labs. A machine with 36 GB RAM is enough to run both `mini` and `standalone` comfortably.

For the `mini` profile, a cluster with **3 worker nodes** is suggested so Hadoop, MySQL, Metastore, and HiveServer2 have room to schedule cleanly across the local cluster.

Minimum practical host sizes:

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

standalone + mini:
  host RAM:        32 GB+
  Kubernetes RAM:  20-24 GB+
  CPUs:            6+
  disk:            30 GB+

llap only:
  host RAM:        32 GB+
  Kubernetes RAM:  20-24 GB+
  CPUs:            6+
  disk:            30 GB+
  worker nodes:    2+ (one LLAP daemon per node)

secure only:
  host RAM:        32 GB+
  Kubernetes RAM:  22-26 GB+
  CPUs:            6+
  disk:            50 GB+ (NameNode + 3× DataNode + KDC + MySQL PVCs, 10 Gi each)
  worker nodes:    3+ recommended (three DataNode PVCs; Pending DNs block NameNode format)
```

Run **`llap`** or **`secure`** on their own: **`llap`** adds ZooKeeper, two LLAP daemons (~9 GB together), and Hue; **`secure`** adds a KDC and four Hadoop pods (NN + 3 DN) on top of a **mini-shaped** Hive stack. Stop other profiles first (`stop` keeps their PVCs).

With kind on Docker Desktop, every node is a container in the same VM and reports the whole VM memory as allocatable. Adding nodes gives the scheduler more places to put pods, not more memory; raise the Docker Desktop memory instead.

## KIND cluster for `llap`

The **`llap` profile does not label nodes for you**—not in `hiveCtl.sh`, not in the Kubernetes manifests. LLAP daemons use **required pod anti-affinity** (at most one `llapdaemon` pod per node) and **prefer** workers that already carry the label `node-role.kubernetes.io/llap`. You must label two workers yourself, or create the cluster from the template below so the last two workers get that label at join time.

**Recommended:** create a six-node kind cluster from [`kind/llap-cluster.yaml`](kind/llap-cluster.yaml) (1 control-plane + 5 workers). With cluster name `desktop`, kind names the workers `desktop-worker` … `desktop-worker5`; the template labels **`desktop-worker4`** and **`desktop-worker5`** automatically:

```bash
kind create cluster --name desktop --config kind/llap-cluster.yaml
kubectl get nodes -L node-role.kubernetes.io/llap
```

If you use an existing cluster (or a different kind cluster name), label two worker nodes **before** `./hiveCtl.sh start llap` (adjust names from `kubectl get nodes`):

```bash
kubectl label node desktop-worker4 desktop-worker5 node-role.kubernetes.io/llap=
```

Without two schedulable, distinct nodes, the second `llapdaemon` replica stays pending. Unlabeled nodes can still run daemons, but the scheduler may spread LLAP onto the same hosts as other heavy pods unless you label dedicated workers.

This template also maps **Hue** to the host: after `./hiveCtl.sh start llap`, open **http://localhost:8888** (full steps in **[Access Hue (llap profile)](#access-hue-llap--secure-profiles)**). That mapping is **not** done by `hiveCtl.sh`; it is in `extraPortMappings` on the control-plane node below.

Recommended local runtime settings:

```text
Docker Desktop:
  memory: 20-24 GB when running both profiles
  CPUs:   6+

kind:
  uses Docker Desktop resources, so size Docker Desktop accordingly

minikube:
  minikube start --memory=24576 --cpus=6
```

The configured memory limits are intentionally higher than JVM heap settings to leave room for JVM overhead and native memory:

```text
Hive containers: 3 Gi limit for 2 Gi heap
Hadoop pod:      6 Gi limit for multiple 1 Gi Hadoop JVMs
MySQL pod:       2 Gi limit
LLAP daemons:    5 Gi limit for 3 Gi heap + 1 Gi off-heap cache
ZooKeeper pod:   512 Mi limit for 256 Mi heap
Hue pod:         2 Gi limit (768 Mi request); uses MySQL database `hue` on the llap mysql Service
```

## Profiles

Profiles are documented **simplest first**, each step adding services and operational complexity:

```text
standalone  →  mini  →  llap  →  secure
  Derby          HDFS+MySQL     + ZooKeeper,      + KDC, 3× DN,
  one pod        one Hadoop      LLAP×2, Hue       Kerberos, Hue
```

### `standalone`

`standalone` runs Hive without HDFS or MySQL. It uses Derby and local PVC-backed warehouse storage.

Start:

```bash
./hiveCtl.sh start standalone
```

Stop:

```bash
./hiveCtl.sh stop standalone
```

Standalone status:

```bash
./hiveCtl.sh status
kubectl get pods,pvc,svc -n standalone
```

Open a shell in the HiveServer2 container:

```bash
kubectl exec pod/hive-0 -c hiveserver2 -n standalone -it -- /bin/bash
```

Switch to the `hive` user:

```bash
su -s /bin/bash - hive
```

Run Beeline using the built-in alias:

```bash
beeline
```

Run a Beeline command directly:

```bash
beeline -e "SHOW DATABASES;"
```

Create a sample table with generated data:

```bash
createTable.sh man managed_3_1 3 1 10 1
beeline -e "SHOW TABLES;"
```

Back up standalone data:

```bash
./hiveCtl.sh backup standalone
```

Restore standalone data:

```bash
./hiveCtl.sh restore standalone ./backups/standalone-YYYYMMDD-HHMMSS
```

Replace `standalone-YYYYMMDD-HHMMSS` with the actual backup directory name.

Cleanup standalone data and namespace:

```bash
./hiveCtl.sh cleanup standalone
```

### `mini`

`mini` runs the full lab stack:

```text
hadoop -> mysql -> hivemetastore -> hiveserver2
```

Start:

```bash
./hiveCtl.sh start mini
```

Stop:

```bash
./hiveCtl.sh stop mini
```

Mini status:

```bash
./hiveCtl.sh status
kubectl get pods,pvc,svc -n mini
```

Check HDFS:

```bash
kubectl exec hadoop-0 -n mini -- hdfs dfs -ls /
```

Open a shell in HiveServer2:

```bash
kubectl exec pod/hiveserver2-0 -n mini -it -- /bin/bash
```

Switch to the `hive` user:

```bash
su -s /bin/bash - hive
```

Run Beeline:

```bash
beeline
```

Run a Beeline command directly:

```bash
beeline -e "SHOW DATABASES;"
```

Create sample tables with generated data:

```bash
createTable.sh man managed_3_1 3 1 10 1
createTable.sh orc external_orc_3_1 3 1 10 1
beeline -e "SHOW TABLES;"
```

Back up mini data:

```bash
./hiveCtl.sh backup mini
```

Restore mini data:

```bash
./hiveCtl.sh restore mini ./backups/mini-YYYYMMDD-HHMMSS
```

Replace `mini-YYYYMMDD-HHMMSS` with the actual backup directory name.

Cleanup mini data and namespace:

```bash
./hiveCtl.sh cleanup mini
```

### `llap`

> **Before you start:** label **two** worker nodes with `node-role.kubernetes.io/llap` (see **[KIND cluster for `llap`](#kind-cluster-for-llap)**). This repo does not apply that label for you; the kind template in `kind/llap-cluster.yaml` is the supported way to get `desktop-worker4` and `desktop-worker5` labeled on a fresh cluster.

**`llap`** builds on **`mini`**: add ZooKeeper, two Hive LLAP daemons, and Hue. Hive pods use **`apache/hive:nightly`** (see **Images by profile**); that build includes the HIVE-29566 Tez-session fix, which matters here because HiveServer2 keeps a Tez session pool warm for LLAP while clients run many queries in the same JVM.

```text
hadoop -> mysql -> zookeeper -> hivemetastore -> llapdaemon (x2) -> hiveserver2 -> hue
```

The LLAP daemons register in ZooKeeper as the `@llap0` cluster. The Tez application master runs inside HiveServer2 (Tez local mode, because the Hadoop pod doesn't start YARN) and sends query fragments to the daemons, which run them on their executors and cache column data off-heap (LLAP IO). HiveServer2 opens a single Tez session at startup and queries take turns on it: inside HiveServer2's JVM, only the first Tez application master can start the LLAP scheduler. Hive Metastore, HiveServer2, and the daemons share `overlays/llap/hivemetastore/hive-site.xml`.

On each Hive pod start, **`staging.sh`** runs **`hadoop checknative`** and sets **`hive.llap.io.enabled`** to `true` only when native **zlib** loads (typical on **linux/amd64**). On **aarch64** nodes with **x86_64** Hadoop natives in the image (common on Apple Silicon KIND), it sets `false` so Iceberg/ORC GROUP BY uses Java decompression instead of failing with `ZlibDecompressor` errors. `./hiveCtl.sh start llap` prints LLAP worker node architecture(s) as a hint; no manual edit is required. Restart Hive pods after changing the cluster or image so staging re-runs.

HiveServer2 registers in ZooKeeper too, and Beeline looks it up there: in `llap`, `BEELINE_URL` points at the `zookeeper` Service, which gives ZooKeeper a stable address (a single ZooKeeper server needs no headless Service). From any Hive pod in the namespace:

```bash
beeline -u "jdbc:hive2://zookeeper.llap.svc.cluster.local:2181/default;serviceDiscoveryMode=zooKeeper;zooKeeperNamespace=hiveserver2" -n hive
```

See what is registered:

```bash
kubectl exec zookeeper-0 -n llap -- zkCli.sh ls /hiveserver2
kubectl exec zookeeper-0 -n llap -- zkCli.sh ls /llap-unsecure/user-hive/llap0/workers
```

HiveServer2 and LLAP daemons archive **`/opt/hive/log`** (and Tez local session history on HiveServer2) to HDFS under `hdfs://nameservice:8020/logs/llap/<service>/<pod-hostname>/` every five minutes and on pod shutdown (`base/hdfs-log-sync.sh`, shared by both). Pull the latest tarball with:

```bash
kubectl exec hadoop-0 -n llap -- hdfs dfs -cat hdfs://nameservice:8020/logs/llap/hiveserver2/hiveserver2-0.hiveserver2-headless.llap.svc.cluster.local/LATEST
```

HiveServer2 runs **two** replicas. Each pod registers in ZooKeeper under `/hiveserver2` with its headless-Service FQDN (`setHostnameAsFQDN` + `hiveserver2-headless`). Beeline and JDBC clients use the ZooKeeper URL in `BEELINE_URL`, so they discover whichever instances are registered without pinning to the `hiveserver2` ClusterIP Service.

The **`hiveserver2` ClusterIP Service** (`hiveserver2.llap.svc.cluster.local:10000`) keeps **ClientIP session affinity** (from `base/service.yaml`). Clients that cannot use ZooKeeper JDBC—**Hue**—connect there so the Hue pod’s source IP stays pinned to one HiveServer2 replica for up to an hour.

Hive Metastore runs **two** replicas behind the `hivemetastore` Service. Clients keep the single URI `thrift://hivemetastore.llap.svc.cluster.local:9083`; the Service uses **ClientIP** session affinity (one hour), so a given client IP is steered to the same pod rather than round-robin. If that pod goes away, **new** connections from the same client are sent to a healthy backend; long-lived Thrift sessions must reconnect (HiveServer2 opens fresh Beeline sessions each time).

Scheduling rules for the two LLAP daemons live in `overlays/llap/llapdaemon/kustomization.yaml` (one daemon per host; prefer `node-role.kubernetes.io/llap`). Node labels are **manual or via the kind template**—see **[KIND cluster for `llap`](#kind-cluster-for-llap)**.

Start:

```bash
./hiveCtl.sh start llap
```

**Open Hue:** see **[Access Hue (llap profile)](#access-hue-llap--secure-profiles)** — typically **http://localhost:8888** (kind + `kind/llap-cluster.yaml`) or `kubectl port-forward svc/hue -n llap 8888:8888`.

Stop:

```bash
./hiveCtl.sh stop llap
```

LLAP status:

```bash
./hiveCtl.sh status
kubectl get pods,pvc,svc -n llap -o wide
```

Check that queries run on LLAP:

```bash
kubectl exec pod/hiveserver2-0 -n llap -it -- /bin/bash
su -s /bin/bash - hive
createTable.sh man managed_3_1 3 1 10 1
beeline -e "EXPLAIN SELECT count(*) FROM managed_3_1;"
beeline -e "SELECT count(*) FROM managed_3_1;"
```

**LLAP daemon UI:** **http://localhost:15002** after start — see **[Access LLAP daemon UI (llap profile)](#access-llap-daemon-ui-llap-profile)** (`hiveCtl` port-forwards **`llapdaemon-0`**).

### Hue (llap SQL UI)

> **Quick access:** **[Access Hue (llap profile)](#access-hue-llap--secure-profiles)** (start command, readiness check, and browser URLs).

**Hue** starts **after** HiveServer2. It uses MySQL database **`hue`** (`hue-mysql-password`, `hue-secret-key` in `hive-credentials`). Queries go to **`hiveserver2.llap.svc.cluster.local:10000`** with user **`hive`** / **`beeline-password`**. Older clusters get Hue keys patched on `./hiveCtl.sh start llap` or `start llap hue`.

#### Deploy Hue

```bash
./hiveCtl.sh start llap          # includes hue
# or
./hiveCtl.sh start llap hue      # hue only (HiveServer2 must already be running)
./hiveCtl.sh stop llap hue
```

`hiveCtl.sh` **only** creates/updates Kubernetes objects and waits for the pod to become Ready. It does **not** open a browser, run `kubectl port-forward`, or bind a port on your laptop.

#### How ports are exposed

| Layer | Role |
|-------|------|
| `overlays/llap/hue/service.yaml` | Kubernetes Service **`hue`**, NodePort **30888** → pod **8888** |
| `kind/llap-cluster.yaml` | Host **http://localhost:8888** → control-plane NodePort **30888** |
| `kubectl port-forward` | Host **http://localhost:8888** on any cluster (see **[Access Hue](#access-hue-llap--secure-profiles)**) |

On **`start llap hue`**, `hiveCtl.sh` also attempts localhost exposure (see **[Access Hue](#access-hue-llap--secure-profiles)**). The Service above is what port-forward connects to.

Back up, restore, and cleanup work the same as `mini`:

```bash
./hiveCtl.sh backup llap
./hiveCtl.sh restore llap ./backups/llap-YYYYMMDD-HHMMSS
./hiveCtl.sh cleanup llap
```

### `secure`

**`secure`** is the most elaborate profile: **mini-shaped** Hive + MySQL + Hue, but with **distributed Kerberos HDFS** (one NameNode + **three DataNodes**, **`dfs.replication=3`**), **two** Hive Metastore and **two** HiveServer2 pods, and **Hue**. Namespace and profile name: **`secure`**. Manifests live under **`components/hadoop-namenode`**, **`components/hadoop-datanode`**, **`components/krb5kdc`**, and **`overlays/secure/*`**.

```text
krb5kdc -> hadoop-namenode (+ 3× hadoop-datanode) -> mysql -> hivemetastore -> hiveserver2 -> hue
```

**HDFS**, **Hive Metastore/HS2**, and **Hue→HS2** use **Kerberos**; the Hue **web UI** remains username/password (not SPNEGO). MySQL is not Kerberized.

Start order is enforced by **`hiveCtl.sh start secure`** (KDC first, then Hadoop, then the rest). NameNode bootstrap waits until **three live DataNodes** register; the first start can take several minutes.

```bash
./hiveCtl.sh start secure
# or step-by-step:
./hiveCtl.sh start secure krb5kdc
./hiveCtl.sh start secure hadoop-namenode   # applies NN + 3 DNs together
./hiveCtl.sh start secure mysql
./hiveCtl.sh start secure hivemetastore
./hiveCtl.sh start secure hiveserver2
./hiveCtl.sh start secure hue
```

Stop the full profile or individual components (Hadoop stop drops **both** NameNode and DataNode StatefulSets):

```bash
./hiveCtl.sh stop secure
./hiveCtl.sh stop secure hadoop-namenode
```

Status and shells:

```bash
./hiveCtl.sh status
kubectl get pods,pvc,svc -n secure -o wide
kubectl exec -it hadoop-namenode-0 -n secure -- bash
kubectl exec -it hiveserver2-0 -n secure -- su - hive
```

#### MIT Kerberos (KDC)

StatefulSet **`krb5kdc-0`** runs **`krb5-kdc`** and **`kadmind`** on **`debian:bookworm-slim`**, realm **`SECURE.LAB`**, Service **`krb5kdc`** on **88** / **749**. The KDB persists on PVC **`krb5kdc-data-krb5kdc-0`**.

Lab principals include **`admin/admin@SECURE.LAB`**, **`kadmin/admin@SECURE.LAB`**, **`root/admin@SECURE.LAB`** (password: Secret **`krb5-kadmin-password`**), plus host SPNs such as **`hdfs/<pod-fqdn>@SECURE.LAB`**, **`hive/<pod-fqdn>@SECURE.LAB`**, and **`hue/<pod-fqdn>@SECURE.LAB`** for each entry in **`secure-lab-hosts.list`** (`components/krb5kdc/configmap.yaml`).

**`hiveCtl.sh`** waits for host keytabs on the KDC PVC, then copies **`*.keytab`** into Secret **`kerberos-keytabs`**. Pods mount them at **`/var/kerberos/incoming/`**; bootstrap installs **`${POD_NAME}.keytab`** as **`host-service.keytab`** (**`KRB5_KTNAME`**). Hive and Hadoop use **headless Services** so **`hostname -f`** matches those FQDNs.

#### HDFS (NameNode + DataNodes)

**`overlays/secure/hadoop-namenode`** and **`hadoop-datanode`** set **`hadoop.security.authentication=kerberos`**, block access tokens, and **`dfs.data.transfer.protection=authentication`**. DataNodes require **`dfs.http.policy=HTTPS_ONLY`** and generate lab TLS keystores at bootstrap (`components/hadoop-datanode/configmap.yaml`). The NameNode uses an explicit **`hdfs/<nn-fqdn>@SECURE.LAB`** principal (not **`hdfs/_HOST`**) because **`fs.defaultFS`** is **`hdfs://nameservice`**. HDFS admin CLI and backups use pod **`hadoop-namenode-0`**, not **`hadoop-0`**.

#### Hive (Metastore + HiveServer2)

**`overlays/secure/hivemetastore`** and **`hiveserver2`** merge **`core-site.xml`**, **`hdfs-site.xml`**, and **`hive-site.xml`**: Thrift SASL on the Metastore, **`hive.server2.authentication=KERBEROS`**, per-host **`hive/<pod-fqdn>@SECURE.LAB`** keytabs, and **`hive.server2.enable.doAs=false`**. Metastore Thrift URIs list headless pod FQDNs. Hive **`hdfs-site.xml`** includes a minimal **nameservice** HA client block so Kerberos delegation tokens resolve against **`hdfs://nameservice`**. **`start-hive.sh`** runs **`kinit`** when **`HIVE_KERBEROS=1`**.

Kerberos Beeline from an HS2 pod (interactive shell, or **`script -qefc 'beeline ...' /dev/null`** for non-TTY **`kubectl exec`**):

```bash
kubectl exec -it hiveserver2-0 -n secure -- su - hive
beeline -u "${BEELINE_URL}" -e "select 1;"
beeline -u 'jdbc:hive2://hiveserver2-0.hiveserver2-headless.secure.svc.cluster.local:10000/default;principal=hive/hiveserver2-0.hiveserver2-headless.secure.svc.cluster.local@SECURE.LAB' -e 'show databases;'
```

#### Secure Hue

<a id="secure-hue"></a>

**`overlays/secure/hue`** mounts the **`hue-0`** keytab (**`hue/<hue-fqdn>@SECURE.LAB`**), configures **`[desktop] [[kerberos]]`** (**`krb5_renewlifetime_enabled=false`**, **`keytab_reinit_frequency=3600`** so Hue re-**`kinit`**s from the keytab instead of **`kinit -R`**), and **`[beeswax]`** with **`use_sasl=true`** to **`hiveserver2-0`** headless FQDN. JDBC to HS2 uses Kerberos; the browser login stays Hue’s local user database.

**Open Hue:** **[Access Hue (llap / secure)](#access-hue-llap--secure-profiles)** — **http://localhost:8888** (port-forward) or NodePort **30889** (`overlays/secure/hue/service.yaml`).

```bash
./hiveCtl.sh start secure hue
kubectl port-forward svc/hue -n secure 8888:8888
```

#### Backup, restore, cleanup

Same workflow as **`mini`**, with secure-specific PVCs and HDFS backup via **`hadoop-namenode-0`** (Kerberos **`kinit`** inside the pod):

```bash
./hiveCtl.sh backup secure
./hiveCtl.sh restore secure ./backups/secure-YYYYMMDD-HHMMSS
./hiveCtl.sh cleanup secure
```

**`cleanup secure`** deletes PVCs: **`mysql-mysql-0`**, **`pvc-hdfs-nn`**, **`datanode-data-hadoop-datanode-{0,1,2}`**, **`krb5kdc-data-krb5kdc-0`**, then the namespace. Restore after cleanup reapplies **`hive-credentials.secret.json`**, starts **KDC → Hadoop → MySQL**, loads MySQL + HDFS from the backup, then starts Hive and Hue.

Lab users **`admin`**, **`hadoop`**, and **`hive`** are in Unix group **`supergroup`** on Hadoop pods (`components/hadoop-namenode` / `hadoop-datanode` bootstrap).


## Data Safety

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

## Bootstrap Model

The startup scripts use `root` to:

- install missing packages with retry logic (Hadoop installs its tools in the background and keeps the RPMs on its volume under `/hdfs/rpm-cache`, so only the first start of a new volume needs the CentOS mirrors)
- copy mounted ConfigMap files into Hive/Hadoop config directories
- prepare users, permissions, SSH, and symlinks
- ensure Unix group **`supergroup`**, add **`hive`** to it, and create OS user **`admin`** (also in **`supergroup`**) with fixed lab password **`admin`** — see **[Lab OS users](#lab-os-users-supergroup)**

The long-running services then run as:

- `hadoop` for Hadoop (**`mini`** / **`llap`**: one pod; **`secure`**: NameNode and DataNode pods)
- `hive` for Hive Metastore, HiveServer2, and the LLAP daemons
- `zookeeper` for ZooKeeper (`llap` only; the image drops privileges itself)
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

## Smoke Tests

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

LLAP Hue — see **[Access Hue (llap profile)](#access-hue-llap--secure-profiles)**:

```bash
kubectl get pods,svc -n llap -l app=hue
kubectl wait --for=condition=ready pod -l app=hue -n llap --timeout=300s
# → http://localhost:8888 (kind template or port-forward)
```

LLAP daemon UI — see **[Access LLAP daemon UI](#access-llap-daemon-ui-llap-profile)**:

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

Secure Hue — see **[Access Hue (llap / secure)](#access-hue-llap--secure-profiles)**:

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
         overlays/secure/hivemetastore overlays/secure/hiveserver2 overlays/secure/hue; do
  kustomize build "$d" --load-restrictor LoadRestrictionsNone | kubectl apply --dry-run=client -f -
done
```

Lint the controller script:

```bash
shellcheck hiveCtl.sh
```
