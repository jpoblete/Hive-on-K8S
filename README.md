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

## Images by profile

```text
standalone:   apache/hive:4.2.0   (embedded Metastore + HiveServer2 in one pod)
mini:         apache/hive:4.2.0   (Hive Metastore + HiveServer2)
llap:         apache/hive:nightly (Hive Metastore x2, HiveServer2 x2, LLAP daemon x2)
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
```

Run `llap` on its own: its two LLAP daemons alone use about 9 GB, so stop `standalone` and `mini` first (`stop` keeps their PVCs).

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
```

## Profiles

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

`llap` is `mini` plus ZooKeeper and two Hive LLAP daemons. Hive pods use **`apache/hive:nightly`** (see **Images by profile**); that build includes the HIVE-29566 Tez-session fix, which matters here because HiveServer2 keeps a Tez session pool warm for LLAP while clients run many queries in the same JVM.

```text
hadoop -> mysql -> zookeeper -> hivemetastore -> llapdaemon (x2) -> hiveserver2
```

The LLAP daemons register in ZooKeeper as the `@llap0` cluster. The Tez application master runs inside HiveServer2 (Tez local mode, because the Hadoop pod doesn't start YARN) and sends query fragments to the daemons, which run them on their executors and cache column data off-heap (LLAP IO). HiveServer2 opens a single Tez session at startup and queries take turns on it: inside HiveServer2's JVM, only the first Tez application master can start the LLAP scheduler. Hive Metastore, HiveServer2, and the daemons share `overlays/llap/hivemetastore/hive-site.xml`.

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

Hive Metastore runs **two** replicas behind the `hivemetastore` Service. Clients keep the single URI `thrift://hivemetastore.llap.svc.cluster.local:9083`; the Service uses **ClientIP** session affinity (one hour), so a given client IP is steered to the same pod rather than round-robin. If that pod goes away, **new** connections from the same client are sent to a healthy backend; long-lived Thrift sessions must reconnect (HiveServer2 opens fresh Beeline sessions each time).

Scheduling rules for the two LLAP daemons live in `overlays/llap/llapdaemon/kustomization.yaml` (one daemon per host; prefer `node-role.kubernetes.io/llap`). Node labels are **manual or via the kind template**—see **[KIND cluster for `llap`](#kind-cluster-for-llap)**.

Start:

```bash
./hiveCtl.sh start llap
```

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

Open an LLAP daemon web UI at <http://localhost:15002>:

```bash
kubectl port-forward pod/llapdaemon-0 -n llap 15002:15002
```

Back up, restore, and cleanup work the same as `mini`:

```bash
./hiveCtl.sh backup llap
./hiveCtl.sh restore llap ./backups/llap-YYYYMMDD-HHMMSS
./hiveCtl.sh cleanup llap
```

## Data Safety

PVCs hold the persistent data. Deleting PVCs can cause data loss.

`hiveCtl.sh` creates namespace-local Kubernetes Secrets at startup instead of storing passwords in Git. Backups include a portable copy of those generated credentials:

```text
hive-credentials.secret.json
```

Treat backup directories as sensitive because they contain both data and credentials.

`stop` keeps the PVCs and gives each pod its grace period to shut its services down cleanly. When the Kubernetes API can't be reached, `hiveCtl.sh` reports the error and stops rather than treating components as stopped or missing.

Use backup before cleanup:

```bash
./hiveCtl.sh backup standalone
./hiveCtl.sh backup mini
./hiveCtl.sh backup llap
```

Restore:

```bash
./hiveCtl.sh restore standalone <backup-dir>
./hiveCtl.sh restore mini <backup-dir>
./hiveCtl.sh restore llap <backup-dir>
```

Restore also works after cleanup or on a new cluster: it creates the namespace with the backed-up credentials, starts the storage, loads the backup, and then starts the rest of the stack. If MySQL already has a volume, the current credentials are kept, because MySQL created its users with them and the metastore dump doesn't include users.

Destructive cleanup requires confirmation and offers to create a backup first:

```bash
./hiveCtl.sh cleanup standalone
./hiveCtl.sh cleanup mini
./hiveCtl.sh cleanup llap
```

## Bootstrap Model

The startup scripts use `root` to:

- install missing packages with retry logic (Hadoop installs its tools in the background and keeps the RPMs on its volume under `/hdfs/rpm-cache`, so only the first start of a new volume needs the CentOS mirrors)
- copy mounted ConfigMap files into Hive/Hadoop config directories
- prepare users, permissions, SSH, and symlinks

The long-running services then run as:

- `hadoop` for Hadoop
- `hive` for Hive Metastore, HiveServer2, and the LLAP daemons
- `zookeeper` for ZooKeeper (`llap` only; the image drops privileges itself)

This keeps the upstream images unchanged while still making the lab reproducible.

The Hadoop container restarts itself when HDFS stops answering: its liveness probe runs `hdfs dfs -ls -R /` and checks the DataNode port every 30 seconds, and three failures in a row restart it. The daemon logs live on the Hadoop volume under `/hdfs/logs`, so they survive the restart for a post mortem:

```bash
kubectl exec hadoop-0 -n mini -- ls -l /hdfs/logs
```

Deleting the Hadoop pod stops the HDFS daemons cleanly, in reverse start order, instead of waiting out the grace period. YARN stays configured but isn't started, since HiveServer2 runs Tez itself; to bring it back, add the ResourceManager and NodeManager to the daemon list in `components/hadoop/configmap.yaml`.

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

## Validation

Render all overlays:

```bash
for d in overlays/standalone/hive \
         overlays/mini/hadoop overlays/mini/mysql overlays/mini/hivemetastore overlays/mini/hiveserver2 \
         overlays/llap/hadoop overlays/llap/mysql overlays/llap/zookeeper overlays/llap/hivemetastore overlays/llap/llapdaemon overlays/llap/hiveserver2; do
  kustomize build "$d" --load-restrictor LoadRestrictionsNone | kubectl apply --dry-run=client -f -
done
```

Lint the controller script:

```bash
shellcheck hiveCtl.sh
```
