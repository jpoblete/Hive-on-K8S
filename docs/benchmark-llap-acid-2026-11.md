# Apache Hive LLAP & ACID Performance Benchmark Report

| | |
| --- | --- |
| **Environment** | Secure BigData-on-K8S (Kerberos enabled) |
| **Author** | José Manuel Martínez Poblete |
| **Date** | November 6, 2026 |

This is the project’s **reference performance report** for Hive-on-Kubernetes: LLAP behaviour, partition pruning, a heavy window/cross-join spill case, and managed ACID mutations. The [README](../README.md) links here under **Performance**.

For stack details and commands, see [README.md](../README.md) and [Secure profile](secure-profile.md).

---

## 1. Executive summary

This report summarizes methodology and results for a secure, containerized **Apache Hive 4.3.0-SNAPSHOT** deployment on Kubernetes (e.g. kind with port mappings and worker nodes on a real cluster).

Goals:

1. **Low-latency analytical processing (LLAP)** — cache efficiency, vectorization, and Tez/LLAP behaviour under heavy analytical window workloads.
2. **ACID (`DbTxnManager`)** — INSERT / UPDATE / DELETE / SELECT performance and reads across transaction deltas.

Observed: sub-second DAG times for tuned analytical queries, strong partition pruning, and graceful disk spill under synthetic memory pressure without pod failure.

---

## 2. Benchmark methodology

To limit skew from cached results, queries used non-deterministic constructs (e.g. `RAND()`) or distinct string-heavy expressions so work was computed at query time.

### Core test dataset

| Item | Value |
| --- | --- |
| Tables | `default.ice_orc_ext_3_1_10k` (external), `default.orc_acid` (managed ACID) |
| Row count | 10,000 baseline rows |
| Format | ORC (vectorized) |
| Partitioning | Column `p1` |

### Dataset generation & DDL

The baseline Iceberg/ORC external table was generated using `/opt/hive/setup/createTable.sh` inside `hiveserver2-0` (1,000 rows per partition × 10 random `p1` partitions = 10,000 rows):

```bash
cd /opt/hive/setup
./createTable.sh ice_orc default.ice_orc_ext_3_1_10k 3 1 1000 10
```

**Generated External Iceberg DDL (`default.ice_orc_ext_3_1_10k`):**

```sql
CREATE EXTERNAL TABLE IF NOT EXISTS default.ice_orc_ext_3_1_10k (
  c1 int,
  c2 string,
  c3 string
)
PARTITIONED BY (p1 int)
STORED BY ICEBERG
STORED AS ORC;
```

**Managed ACID Table DDL & Hydration (`default.orc_acid`):**

```sql
CREATE TABLE IF NOT EXISTS default.orc_acid (
  c1 int,
  c2 string,
  c3 string
)
PARTITIONED BY (p1 int)
CLUSTERED BY (c1) SORTED BY (c1 ASC) INTO 128 BUCKETS
STORED AS ORC
TBLPROPERTIES ('transactional'='true');

INSERT INTO default.orc_acid PARTITION (p1)
SELECT c1, c2, c3, p1
FROM default.ice_orc_ext_3_1_10k;
```

### Execution configuration (ACID tests)

```sql
SET hive.support.concurrency=true;
SET hive.txn.manager=org.apache.hadoop.hive.ql.lockmgr.DbTxnManager;
```

---

## 3. Test phase 1: Analytical and LLAP processing

### A. Synthetic memory exhaustion (cross-join multiplier)

Full table self-join on `p1` → **1,000,000** intermediate rows.

```sql
WITH stream_a AS (
  SELECT c1, c2, c3, p1, LENGTH(c2) + LENGTH(c3) AS text_len_hash
  FROM default.ice_orc_ext_3_1_10k
),
stream_b AS (
  SELECT c1, c2, c3, p1, REVERSE(c2) AS rev_c2
  FROM default.ice_orc_ext_3_1_10k
)
SELECT a.p1,
       DENSE_RANK() OVER (PARTITION BY a.p1 ORDER BY CONCAT(a.c2, '-', b.rev_c2) DESC)
FROM stream_a a
JOIN stream_b b ON a.p1 = b.p1;
```

| Metric | Value |
| --- | --- |
| Wall / total | **143.61 s** |
| Tez / reducers | Heavy reducer phase (~136.60 s on Reducer 4) with wide analytic window (`ROWS BETWEEN 500 PRECEDING`) |
| Spill | ~**177.22 MB** to local scratch (`FILE_BYTES_WRITTEN`); no pod crash |
| Parallelism | **14** containers across **2** workers |

### B. Bounded and vectorized dashboard benchmarks

Run in a TTY-attached session (avoids JLine non-TTY issues).

**Test 1 — cache warm vs hit**

```sql
SELECT p1, COUNT(1), COUNT(DISTINCT c2), AVG(c1)
FROM default.ice_orc_ext_3_1_10k
GROUP BY p1;
```

| Run | DAG runtime |
| --- | --- |
| Warmer | **0.56 s** |
| Hit | **0.58 s** |

LLAP path: **META_HIT** / **DATA_HIT**, **0 B** read from HDFS on the hit run.

**Test 2 — partition pruning**

```sql
SELECT c1, c2, c3
FROM default.ice_orc_ext_3_1_10k
WHERE p1 = 1
ORDER BY c1 DESC
LIMIT 50;
```

| Metric | Value |
| --- | --- |
| DAG runtime | **0.11 s** |

**Test 3 — heavy vectorized strings**

```sql
SELECT p1,
       SUM(HASH(c2)),
       AVG(LENGTH(c2)),
       MAX(CONCAT(LOWER(c2), '_', UPPER(c3)))
FROM default.ice_orc_ext_3_1_10k
GROUP BY p1;
```

| Metric | Value |
| --- | --- |
| DAG runtime | **0.72 s** |

---

## 4. Test phase 2: Managed ACID scaling

Transactional table: `TBLPROPERTIES ('transactional'='true')`.

### Executed SQL queries

**ACID 1 — DELETE (row removal across partitions, 1,000 rows affected)**

```sql
DELETE FROM default.orc_acid
WHERE c1 % 10 = 0;
```

**ACID 2 — UPDATE (partition-pruned predicate, 0 rows affected)**

```sql
UPDATE default.orc_acid
SET c2 = CONCAT(c2, '_updated')
WHERE p1 = 1;
```

**ACID 3 — SELECT across deltas (reconciling base ORC + delete deltas)**

```sql
SELECT p1,
       c1 % 100 AS bucket_group,
       COUNT(1) AS active_rows,
       AVG(LENGTH(c2)) AS avg_len
FROM default.orc_acid
GROUP BY p1, c1 % 100
LIMIT 100;
```

### Results

| Step | Operation | DAG time | Client / wall | Rows |
| --- | --- | --- | --- | --- |
| Hydrate | `INSERT … SELECT` into ACID table | 3.41 s | 8.848 s | 10,000 |
| ACID 1 | `DELETE` (row removal) | 4.81 s | 9.486 s | 1,000 |
| ACID 2 | `UPDATE` (partition-pruned predicate) | 0.07 s | 0.567 s | 0 |
| ACID 3 | `SELECT` across deltas | 1.80 s | 2.391 s | 100 |

### Transactional mechanics (observed)

1. **Deletion (~4.81 s DAG)** — `DELETE WHERE c1 % 10 = 0` scanned broadly; Hive recorded **delete_delta** metadata instead of rewriting base ORC wholesale.
2. **Update (~0.07 s DAG)** — predicate targeted a single partition (`WHERE p1 = 1`); pruning limited work.
3. **Delta read (~1.80 s DAG)** — aggregation reconciled base ORC with active delete deltas via LLAP/Tez.

---

## 5. Summary

The **secure** BigData-on-K8S stack showed sensible LLAP cache hits, partition pruning, ACID mutations, and controlled spill under an extreme windowed join. Kerberos did not dominate these timings.

**Operational note:** Very large analytic window frames can force sort spills and long reducer phases; keep window history bounds modest for predictable behaviour.
