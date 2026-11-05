# LLAP compaction and cleaner anomalies

Observed on the **llap** overlay, Hive **4.3.0-SNAPSHOT** (`apache/hive:nightly`), 4 Nov 2026. Workload: transactional ORC tables `compactor_test` and `compactor_test-2` through `compactor_test-5`, with insert, update, a ranking query, and delete running on `hivemetastore-0`.

Logs:

- Metastore: `/opt/hive/log/hivemetastore-hivemetastore-0.hivemetastore-headless.llap.svc.cluster.local-1793831746.log` (process started 22:35:55 UTC)
- Workers: `/opt/hive/log/hiveserver2-*.log` on `hiveserver2-0` and `hiveserver2-1`
- Queue: MySQL `hive.COMPACTION_QUEUE`, `hive.COMPLETED_COMPACTIONS`

Through 23:01 UTC this process had requested compactions, finished them, and cleaned **12** of them (ids 56–67). All 12 completed with state `s`. None were left in `ready for cleaning`. The items below are the places where that still did not match the configured or expected behavior.

## 1. Initiator and Cleaner never started after leadership failed

**When:** 20:18:49 UTC until the pod was recreated at 22:35:55 UTC.

**What:** On the previous `hivemetastore-0` process, housekeeping leadership called `org.apache.iceberg.mr.hive.compaction.IcebergTableOptimizer` before the Thrift metastore was accepting connections. The client got `Connection refused` to `thrift://hivemetastore.llap.svc.cluster.local:9083`. `StaticLeaderElection` logged `Error while notifying the listener: CompactorTasks` and wrapped the failure as `CompactionException: Failed instantiating and calling table optimizer`.

**Why it stayed down:** That callback is not retried. `Starting Initiator thread` and `Starting Cleaner thread` were absent for the rest of that process, so the queue was not scanned and nothing was cleaned. HiveServer2 workers had already started at 20:19:25 and stayed up; they had nothing to run.

**Recovery:** Deleting `hivemetastore-0` started a new process. At 22:35:55 it logged both thread starts. The first real initiator pass was 22:40:56.

## 2. Four configured keys are unknown to this build

At 22:35:55 the new metastore logged `HiveConf of name … does not exist` once each for:

| Key in `overlays/llap/hivemetastore/hive-site.xml` | What the process actually used |
|---|---|
| `hive.metastore.housekeeping.threads.on` | Unknown. Initiator and Cleaner still started. |
| `hive.metastore.housekeeping.leader.hostname` | Unknown under the `hive.` name. The value was applied as `metastore.housekeeping.leader.hostname` = `hivemetastore-0.hivemetastore-headless.llap.svc.cluster.local`. |
| `hive.compactor.cleaner.on` | Unknown under the `hive.` name. Logged effective value `metastore.compactor.cleaner.on = true`. |
| `hive.metastore.runworker.in=hs2` | Ignored. No `runworker` setting took effect. |

`hive.compactor.initiator.on`, `hive.compactor.worker.threads`, and `hive.compactor.cleaner.threads.num` did not warn. The metastore logged `metastore.compactor.initiator.on = true` and `metastore.compactor.worker.threads = 5`.

Workers still ran only on HiveServer2. The metastore log has no `compactor.Worker: Starting Worker thread`. HS2 started its workers because `hive.compactor.worker.threads=5` is in the shared hive-site, not because `hive.metastore.runworker.in` was honored.

`metastore.housekeeping.leader.election=host` is required on this build. Without it, election uses the lease lock and the hostname is ignored. Both HMS pods stayed non-leaders until this was set. That was fixed before this log; it is why a hostname-only change is not enough.

## 3. Cleaner pool of 5 never leaves thread 0

`hive.compactor.cleaner.threads.num=5` is set. Every clean in this process was logged on `Cleaner-executor-thread-0`, including the passes that had five tables ready at once:

- 22:56:09.700–.703 UTC, ids 58–62, all thread 0, then five `FSRemover` lines on thread 0
- 23:01:10.425–23:01:15.491 UTC, ids 63–67, all thread 0

No `Cleaner-executor-thread-1` (or higher) appears. Initiator checks are likewise only `Initiator-executor-thread-0`.

The worker side does fan out. At 23:01:01 on `hiveserver2-0`, ids 68–72 were taken together by five different `*_timeout_executor` threads (53, 54, 56, 58, 60).

## 4. MarkCleaned warns on every successful clean

**Count:** 12 cleans, 12 warnings, 0 failures. Each warning is:

```
functions.MarkCleanedFunction: Expected to remove at least one row from completed_txn_components when marking compaction entry as clean!
```

The completed row still moved to state `s` within the same second. `Leaving queue entry` and `unable to complete cleaning` are absent.

`hive.COMPLETED_TXN_COMPONENTS` is not empty. The rows present at 23:01 belonged to newer write ids (14 and above) than the compactions being marked clean (highest write id 8–19 on the earlier ids). The delete inside `MarkCleaned` matched nothing for the compaction it had just finished. Treat the warning as a bookkeeping miss, not as a failed clean.

## 5. Compaction jobs are local and named `null-compactor-…`

Workers log this shape (ids 68–72, 23:01:06 UTC, `hiveserver2-0`):

```
Submitted compaction job 'null-compactor-default.compactor_test' with jobID=job_local399083533_0002 compaction ID=68
```

The same `null-compactor-` prefix and `job_local…` id were used for `compactor_test-2` through `compactor_test-5`.

- `null-compactor-` is the worker id string concatenated in front of the table name. `Processing compaction request` shows `workerId=<null>`, and `COMPLETED_COMPACTIONS.CC_WORKER_ID` is NULL on ids 56–62. The worker id is never recorded.
- `job_local…` means the MapReduce compaction ran inside the HiveServer2 JVM, not as a YARN application.

Both are consistent across the jobs checked. The compactions still reached `ready for cleaning` and then `s`.

## Not failures

These showed up in the same window and are expected for this workload:

- **Five-minute cadence.** The cleaner and initiator wake about every 300 seconds from 22:35:55 (22:40, 22:46, 22:51, 22:56, 23:01). Compaction 56 became ready at 22:41:03, just after the 22:40 wake, so its clean waited until 22:46:12. Ids 68–72 were `ready for cleaning` at the end of this note and wait for the next wake.
- **AcidHouseKeeper is a different cleaner.** Lines `CompactionTxnHandler: Start to clean empty aborted or committed TXNS` and `CleanTxnToWriteIdTableFunction` come from the housekeeping txn reaper, not from `compactor.Cleaner`.
- **First scan of the numbered tables.** At 22:45:56 the initiator checked `compactor_test-2` through `-5` and did not request a compaction. They did not have enough deltas yet. At 22:50:56 it requested a major for all five.
- **Open readers.** Several cleans logged a real min open write id (13–29) rather than `9223372036854775807`. The cleaner still removed the obsolete delta directories and marked the row `s`. It did not log `Leaving queue entry`.
- **Escaped paths.** `FSRemover` prints `compactor_test-45-4` (and `-2`, `-3`, `-5`). That is the warehouse directory for `compactor_test-4`: Hive wraps the hyphen (ASCII 45) in path-escape markers, which the log line does not show as separate characters.
- **A new major every cycle.** With inserts and updates arriving every minute, the initiator requests another major while the previous one is still `ready for cleaning`. The following clean deletes the previous base (for example `base_0000015_v0001134`) as obsolete. That is the cleaner removing a superseded base, not a dropped compaction.
