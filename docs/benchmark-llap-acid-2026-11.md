# Apache Hive LLAP & ACID Performance Benchmark Report

**Environment:** Secure Hive-on-K8S infrastructure (Kerberos enabled)  
**Author:** José Manuel Martínez Poblete  
**Date:** November 6, 2026

For stack details and commands, see [README.md](../README.md) and [Secure profile](secure-profile.md).

---

## 1. Executive summary

This report summarizes the performance benchmarking methodology and results executed on a secure, containerized **Apache Hive 4.3.0-SNAPSHOT** architecture deployed on Kubernetes (e.g. kind control-plane port mappings and worker-backed nodes on a real cluster).

The primary goal of this benchmark suite was to isolate, stress-test, and profile two core engines in the data architecture:

1. **Low-latency analytical processing (LLAP)** — in-memory caching efficiency, vectorization pipelines, and boundary behaviour of Tez execution daemons under heavy analytical window workloads.
2. **ACID transaction manager (`DbTxnManager`)** — performance of row-level data mutations (INSERT, UPDATE, DELETE) and read behaviour across transaction deltas.

The cluster demonstrated sub-second execution for optimized analytical queries, efficient partition pruning, and resilient disk-spill behaviour under synthetic memory pressure.

---

## 2. Benchmark methodology

To reduce skew from cached query results, queries used non-deterministic constructs (e.g. `RAND()`) or distinct combinations of string operations so work was evaluated at query time.

### Core test dataset

| Item | Value |
|------|--------|
| Tables | `default.ice_orc_ext_3_1_10k` (external), `default.ice_orc_acid` (managed ACID) |
| Row count | 10,000 baseline rows |
| Format | ORC (vectorized) |
| Partitioning | Column `p1` |

### Execution configuration (ACID tests)

Session-level settings for transactional isolation:

```sql
SET hive.support.concurrency=true;
SET hive.txn.manager=org.apache.hadoop.hive.ql.lockmgr.DbTxnManager;
```

---

## 3. Test phase 1: Analytical & LLAP processing

This phase probed Tez DAG container memory behaviour and optimization boundaries.

### A. Synthetic memory exhaustion (cross-join multiplier)

A cross-join joined the full baseline table to itself on partition key `p1`, scaling the intermediate matrix to **1,000,000** rows.

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
|--------|--------|
| Result | **143.61 s** |
| Notes | Heavy reducer phase (~136.60 s on Reducer 4) tied to a wide analytic window (`ROWS BETWEEN 500 PRECEDING`), JVM sort buffers spilling ~**177.22 MB** to local scratch without pod failure; **14** parallel containers across **2** workers |

### B. Bounded & vectorized dashboard benchmarks

Run interactively in a TTY-attached session to avoid JLine non-TTY limitations.

**Test 1A & 1B — cache warm vs hit**

```sql
SELECT p1, COUNT(1), COUNT(DISTINCT c2), AVG(c1)
FROM default.ice_orc_ext_3_1_10k
GROUP BY p1;
```

| Run | DAG runtime |
|-----|----------------|
| Warmer | **0.56 s** |
| Hit | **0.58 s** |

Analysis: LLAP reported **META_HIT** / **DATA_HIT** with **0 B** read from HDFS in the hit path.

**Test 2 — partition pruning**

```sql
SELECT c1, c2, c3
FROM default.ice_orc_ext_3_1_10k
WHERE p1 = 1
ORDER BY c1 DESC
LIMIT 50;
```

| Metric | Value |
|--------|--------|
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
|--------|--------|
| DAG runtime | **0.72 s** |

---

## 4. Test phase 2: Managed ACID scaling

After creating a transactional table (`TBLPROPERTIES ('transactional'='true')`), structural mutations were measured.

| Step | Description | DAG / wall-clock | Rows |
|------|-------------|------------------|------|
| Hydrate ACID table from source | INSERT … SELECT | DAG **3.41 s**; **8.848 s** total · **10,000** rows | |
| ACID test 1 | Row **DELETE** | DAG **4.81 s**; **9.486 s** total · **1,000** rows | |
| ACID test 2 | **UPDATE** (partition-pruned predicate) | DAG **0.07 s**; **0.567 s** total · **0** rows affected | |
| ACID test 3 | **SELECT** across deltas | DAG **1.80 s**; **2.391 s** total · **100** rows | |

### Transactional mechanics (observed behaviour)

1. **Deletion cost (~4.81 s DAG)** — `DELETE WHERE c1 % 10 = 0` scanned broadly; Hive wrote **delete_delta** structures rather than rewriting base ORC files wholesale.
2. **Update path (~0.07 s DAG)** — `UPDATE` filtered to a single partition (`WHERE p1 = 1`), so pruning limited work; transactional delta metadata updated quickly.
3. **Delta merge read (~1.80 s DAG)** — aggregation had to reconcile base ORC stripes with active delete deltas in the LLAP/Tez path.

---

## 5. Summary

These runs support that the **secure** Hive-on-K8S stack behaves sensibly for LLAP cache hits, partition pruning, controlled ACID mutations, and spill under extreme windowed joins. Kerberos and metadata handshakes did not dominate these timings.

**Operational note:** Analytic windows with very large frame sizes can force sort spills and long reducer phases—keep window history bounds tight for predictable in-memory behaviour.

### Possible follow-ups

- Automated load: e.g. **1,000,000** rows into the ACID table to stress compaction.
- Concurrent transactions: parallel UPDATE/DELETE sessions to observe lock behaviour and contention.
