# Sample query logs (where to look)

All paths below are **in this repo** on your machine:

```text
Hive-on-K8S/samples/logging/
```

Open from the project root:

```bash
cd /Users/j.martinez.poblete/Downloads/K8S/Hive-on-K8S
less samples/logging/tez_application_trouble_0001.log
```

Or in **Cursor**: open the `samples/logging/` folder in the file tree and click any `.log` file.

---

## File guide

| File | What it shows |
|------|----------------|
| [`tez_application_1792344761427_0001.cluster.log`](tez_application_1792344761427_0001.cluster.log) | **Real cluster** export from HDFS (secure HS2): map/reduce task **syslog**, **counters** (`INPUT_SPLIT_LENGTH_BYTES`, etc.). |
| [`tez_application_1792344761427_0001.export.log`](tez_application_1792344761427_0001.export.log) | **Generated** successful query: **INFO/WARN** + `LogAggregationType: AGGREGATED` layout. |
| [`tez_application_trouble_0001.log`](tez_application_trouble_0001.log) | **Generated** failure demo: small splits (`INPUT_SPLIT_LENGTH_BYTES` 256–512), **NPE** and **OOM** in task **Diagnostics**, AM **stderr**, WARN about many map tasks. |
| [`llap_application_1792344698416_0001.log`](llap_application_1792344698416_0001.log) | **Generated** LLAP export: **INFO/WARN** block, fragments, **stderr** with stack. |
| [`tez_application_1792344761427_0001.log`](tez_application_1792344761427_0001.log) | Older cluster-style export (LOCAL aggregation label). |
| [`fixtures/`](fixtures/) | Raw inputs used to build the generated `.log` files (not yarn-shaped). |

---

## What to search for (troubleshooting)

| Problem | Open | Search for |
|---------|------|------------|
| Small files / too many splits | `tez_application_*` or `.cluster.log` | `INPUT_SPLIT_LENGTH_BYTES`, many `task attempt started`, WARN `many splits` |
| OOM | `tez_application_trouble_0001.log`, `llap_*` | `OutOfMemoryError`, `heap space`, `Diagnostics:` |
| NPE / Tez failure | `tez_application_trouble_0001.log` | `NullPointerException`, `Status: FAILED`, `LogType:stderr` |
| LLAP executor | `llap_application_*.log` | `Fragment [`, `LogType:stderr` |

---

## Live cluster (same layout as production)

After queries run and sync (or `hdfs-log-sync.sh push`):

```text
hdfs://nameservice:8020/user/hive/logs/<profile>/hiveserver2/<pod-fqdn>/tez/application_<id>.log
hdfs://nameservice:8020/user/hive/logs/llap/llapdaemon/<pod-fqdn>/llap/application_<id>.log
```

Example (secure):

```bash
kubectl exec hadoop-namenode-0 -n secure -- hdfs dfs -cat \
  hdfs://nameservice:8020/user/hive/logs/secure/hiveserver2/hiveserver2-0.hiveserver2-headless.secure.svc.cluster.local/tez/application_<id>.log | less
```

Stable rolling logs (full JVM, all levels configured in log4j — default **INFO**):

```text
.../hiveserver2.log
.../llapdaemon.log
```

Toggle INFO/WARN blocks in exports: **`HIVE_LOG_EXPORT_INFO_WARN=0`** on the pod (default **1**).
