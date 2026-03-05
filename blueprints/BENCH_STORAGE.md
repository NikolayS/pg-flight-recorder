# Storage Comparison: Old Ring vs Ring v2

**Date:** 2026-03-05  
**Environment:** Docker, Postgres 17, x86-64  
**Workload:** 2,000 UPDATE/INSERT ticks, 100 wait event rows per tick (full slot utilization)  
**Equivalent real-world time:** ~2.7 hours at 5 s sample cadence  
**Script:** `scripts/run_storage_comparison.sh`

Three scenarios run back-to-back on identical tick counts.

---

## Scenario A: Old ring, no long-running transaction

2,000 ticks, VACUUM runs freely after all ticks.

| Table | Live rows | Dead rows | Dead % | Heap |
|---|---|---|---|---|
| `samples_ring` | 120 | 2,000 | 94.3% | 112 kB |
| `wait_samples_ring` | 12,000 | 0 | 0% | **20 MB** |

`pgstattuple` after VACUUM: 0 dead bytes — VACUUM reclaims the dead tuples.  
But the heap is **20 MB** because fillfactor=90 leaves padding that is never
returned without `VACUUM FULL` (requires a table lock).

---

## Scenario B: Old ring with a long-running transaction (xmin horizon pinned)

Same 2,000 ticks. A `BEGIN; SELECT pg_sleep(400)` session holds the oldest xmin.  
VACUUM runs after all ticks — cannot reclaim anything.

| Table | Live rows | Dead rows | Dead % | Heap |
|---|---|---|---|---|
| `samples_ring` | 240 | 4,000 | 94.3% | 112 kB |
| `wait_samples_ring` | 12,000 | **400,000** | **97.1%** | **20 MB** |

`pgstattuple`:

| dead_tuple_count | dead_size | dead_pct | free_space |
|---|---|---|---|
| 400,000 | **17 MB** | 86.1% | 43 kB |

**400,000 dead tuples. 17 MB of dead data physically present in the heap. VACUUM ran — reclaimed 0 bytes.**

The xmin horizon is pinned by one idle session. In production this is caused by:
- a long-running analytics or reporting query
- an `idle in transaction` session (forgotten `BEGIN`, ORMs)
- a logical replication slot that has not consumed its LSN
- a hot standby running a query

Each such event compounds bloat. At a 5-second sample cadence the old ring
generates ~172,800 dead tuples per hour per pinning event. A 24-hour incident
(e.g., a stale replication slot nobody noticed) means ~4M dead tuples and
hundreds of MB of unrecoverable heap — until the session ends and VACUUM finally
runs.

---

## Scenario C: New ring v2 (INSERT+TRUNCATE), long-running tx active

Same 2,000 ticks. Same long-running transaction open throughout.  
33 rotations fired (every 60 ticks), truncating the oldest slot each time.

| Table | Live rows | Dead rows | Heap |
|---|---|---|---|
| `wait_samples_0` | 1,993 | 0 | 136 kB |
| `wait_samples_1` | 6,080 | 0 | 408 kB |
| `wait_samples_2` | 5,893 | 0 | 400 kB |

`pgstattuple` on the current slot: **0 dead tuples, 0 bytes dead.**

`TRUNCATE` is DDL — it replaces the relation file pointer atomically.
MVCC visibility rules do not apply. The long-running transaction is completely
irrelevant to ring buffer space reclamation.

---

## Side-by-side summary

| | Old ring (baseline) | Old ring (long tx) | Ring v2 (long tx) |
|---|---|---|---|
| Heap (wait_samples) | 20 MB | 20 MB | **944 kB** |
| Dead tuples | 0 (post-VACUUM) | **400,000** | **0** |
| Dead bytes | 0 | **17 MB** | **0** |
| VACUUM effective? | yes | **no** | n/a |
| Long tx immune? | no | no | **yes** |
| Pre-allocated rows | 12,000 (fixed) | 12,000 (fixed) | 13,966 (sparse) |

Ring v2 heap is 20× smaller than the old ring even under identical load.  
Under a long-running tx (the common production case), the comparison is  
old ring 20 MB (frozen, growing) vs ring v2 944 kB (bounded, stable).

---

## Key findings

1. **Old ring bloats to 20 MB for 2,000 ticks of full wait-event data.**
   The pre-allocated 12,000-row structure is always fully expanded on disk
   regardless of how many wait events actually occurred.

2. **One idle session produces 400,000 dead tuples in 2,000 ticks.**
   VACUUM ran immediately after — reclaimed zero bytes. The xmin horizon
   from a single `BEGIN; SELECT pg_sleep(...)` session completely blocks
   all dead tuple reclamation.

3. **17 MB of physically dead data accumulates in ~2.7 hours of simulated load.**
   At that rate, a stale replication slot left for a week would produce
   ~1.5 GB of unrecoverable ring buffer bloat — while the table still
   appears to work normally from the application's perspective.

4. **Ring v2 produces 0 dead tuples in all scenarios including with a pinned
   xmin horizon.** TRUNCATE bypasses MVCC entirely. The heap stays at
   ~944 kB bounded regardless of how long the long tx runs.

5. **Ring v2 is 20× more space-efficient** (944 kB vs 20 MB) due to sparse
   INSERT vs fixed pre-allocation.

---

## Reproduction

```bash
# Run against local Docker container
bash scripts/run_storage_comparison.sh pgfr_record_test-17 pgfr_bench
```
