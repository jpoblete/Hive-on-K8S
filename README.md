# Hive 4.2.0 Kubernetes Lab

## Author

José Martínez-Poblete  
j.martinez.poblete@gmail.com

## Usage Notice

This project is not meant for commercial use without permission and proper credit.

This project runs Apache Hive 4.2.0 on Kubernetes using upstream/minimal container images from Docker Hub.

The manifests intentionally complete the images at pod startup by installing small OS packages and writing runtime configuration from ConfigMaps. Because those images are minimal, the startup scripts use `root` for bootstrap work and then run Hive/Hadoop services as their application users.

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

mini + standalone:
  host RAM:        32 GB+
  Kubernetes RAM:  20-24 GB+
  CPUs:            6+
  disk:            30 GB+
```

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
```

## Profiles

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

## Data Safety

PVCs hold the persistent data. Deleting PVCs can cause data loss.

`hiveCtl.sh` creates namespace-local Kubernetes Secrets at startup instead of storing passwords in Git. Backups include a portable copy of those generated credentials:

```text
hive-credentials.secret.json
```

Treat backup directories as sensitive because they contain both data and credentials.

Use backup before cleanup:

```bash
./hiveCtl.sh backup mini
./hiveCtl.sh backup standalone
```

Restore:

```bash
./hiveCtl.sh restore mini <backup-dir>
./hiveCtl.sh restore standalone <backup-dir>
```

Destructive cleanup requires confirmation and offers to create a backup first:

```bash
./hiveCtl.sh cleanup mini
./hiveCtl.sh cleanup standalone
```

## Bootstrap Model

The startup scripts use `root` to:

- install missing packages with retry logic
- copy mounted ConfigMap files into Hive/Hadoop config directories
- prepare users, permissions, SSH, and symlinks

The long-running services then run as:

- `hadoop` for Hadoop
- `hive` for Hive Metastore and HiveServer2

This keeps the upstream images unchanged while still making the lab reproducible.

## Smoke Tests

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

Standalone Beeline:

```bash
kubectl exec hive-0 -c hiveserver2 -n standalone -it -- /bin/bash
su - hive
beeline -e "show databases;"
```

## Validation

Render all overlays:

```bash
for d in overlays/mini/hadoop overlays/mini/mysql overlays/mini/hivemetastore overlays/mini/hiveserver2 overlays/standalone/hive; do
  kustomize build "$d" --load-restrictor LoadRestrictionsNone | kubectl apply --dry-run=client -f -
done
```

Lint the controller script:

```bash
shellcheck hiveCtl.sh
```
