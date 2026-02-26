# Storage Overhaul: Partition-Based Retention, Zero DELETE

| Version | Date | Author |
|---------|------|--------|
| 1.3 | 2026-02-26 | @NikolayS |

---

## Table of Contents

1. [Background and Motivation](#1-background-and-motivation)
2. [Scope and Constraints](#2-scope-and-constraints)
3. [Storage Analysis: Where the Problem Actually Is](#3-storage-analysis-where-the-problem-actually-is)
4. [Root Cause](#4-root-cause)
5. [Sparse Storage: Store Only What Changed](#5-sparse-storage-store-only-what-changed)
6. [Reader Functions for Sparse Data](#6-reader-functions-for-sparse-data)
7. [Proposed Solution: N Daily Partitions, No DELETE](#7-proposed-solution-n-daily-partitions-no-delete)
8. [Retention Model](#8-retention-model)
9. [Benchmarking and Testing](#9-benchmarking-and-testing)
10. [Open Questions](#10-open-questions)

---

## 1. Background and Motivation

pg-flight-recorder records comprehensive PostgreSQL telemetry continuously via
pg_cron — wait events, active sessions, lock contention, WAL activity, checkpoints,
I/O, table and index statistics, query performance (`pg_stat_statements`),
replication state, and configuration. The data accumulates in a set of LOGGED tables
with DELETE-based retention managed by periodic `cleanup()` calls.

At default configuration (1-minute snapshot interval, 30-day retention,
`pg_stat_statements.max = 5000`), the naive full-insert model for `statement_snapshots`
alone generates approximately 2,024 MiB per day (5,000 queryids × 1,440 ticks/day
× ~280 bytes/row) — and every `cleanup()` run generates that volume as dead tuples
in a single transaction, leaving autovacuum to reclaim gigabytes of bloat per cycle.

This document proposes a storage redesign that eliminates DELETE-based retention
entirely and stops storing redundant data. No changes to what is collected, at what
frequency, or what telemetry is available.

---

## 2. Scope and Constraints

### What this overhaul does

- Stop inserting rows when nothing changed since the last snapshot
- Replace DELETE-based retention with daily partition DROP across all tables
- Introduce N daily partitions where N = configured retention in days
- Eliminate all dead tuples from retention operations

### What this overhaul does NOT do

- **No new metrics** — no additional columns, no new data sources
- **No frequency changes** — snapshot intervals stay as configured
- **No changes to `pgfr_analyze` or `pgfr_control`** — out of scope
- **No changes to safety mechanisms** — circuit breaker, load shedding,
  section timeouts, `snapshot_based_collection` all preserved as-is

### One intentional behavioral change: sparse collection

The collection functions for `statement_snapshots`, `table_snapshots`, and
`index_snapshots` will skip inserting rows when nothing changed since the last
snapshot — following the model already implemented in `config_snapshots`. A missing
row means "no change since the last stored row." Reader functions reconstruct the
full state at any timestamp via `DISTINCT ON ... ORDER BY captured_at DESC`.

---

## 3. Storage Analysis: Where the Problem Actually Is

At default configuration (1-minute snapshots, `pg_stat_statements.max = 5000`,
30-day retention). Two columns shown: naive (full insert every tick) vs actual
current behavior.

**All MiB figures are estimates based on schema analysis and row-count arithmetic.
Baseline measurements against a running installation are part of Phase 1 (§9.2)
and will replace these numbers with observed values.**

| Table | Naive rows at 30d | ~MiB (naive) | Actual insert behavior | ~MiB (actual) | Priority |
|-------|-------------------|--------------|------------------------|----------------|----------|
| `config_snapshots` | 216,000,000 | ~26,000 | **Change-log only** — already implemented upstream | ~1 | P1 |
| `db_role_config_snapshots` | ~43,000,000 | ~4,400 | **Change-log only** — already implemented upstream | ~1 | P1 |
| `statement_snapshots` | 216,000,000 | ~60,000 | Full insert every minute, no dedup | **~60,000** | **P0** |
| `table_snapshots` | 2,160,000 | ~550 | Full insert every minute, no dedup | **~550** | **P0** |
| `index_snapshots` | 2,160,000 | ~260 | Full insert every minute, no dedup | **~260** | **P0** |
| `snapshots` (parent) | 43,200 | ~23 | Full insert every minute | ~23 | **P1** |
| `replication_snapshots` | 86,400 | ~15 | Full insert every minute | ~15 | **P1** |
| `activity_samples_archive` | 168,000 | ~37 | Ring flush every 15 min | ~37 | **P1** |
| Ring buffers (combined) | ~27,000 (fixed) | ~16 | UPDATE overwrite | ~16 | **P2** |
| Aggregate tables (combined) | ~60,000 | ~14 | DELETE retention | ~14 | **P2** |

### Key findings

**`config_snapshots` uses the right approach but has not been benchmarked.**
The upstream `_collect_config_snapshot()` function stores only parameters that
changed since the last snapshot — the correct design and the template for the
remaining tables. However, the `~1 MiB (actual)` figure in the table above is an
estimate, not a measured value. Real-world behavior depends on factors not yet
quantified: how often cloud providers silently reload configuration, how frequently
`pg_reload_conf()` is called, whether connection-level `SET` or `ALTER SYSTEM`
commands affect tracked parameters, and whether the change-detection logic handles
all edge cases correctly. The baseline measurement in §9.2 will establish the true
numbers. There may still be room for improvement — do not treat this as closed
until benchmarks confirm it.

**`statement_snapshots` is the dominant problem.** At `pg_stat_statements.max = 5000`
(the PostgreSQL default), the naive model inserts 5,000 rows every minute regardless
of query activity — approximately 2,024 MiB per day, or 60 GiB at 30-day retention.
A query that ran once 29 days ago has 43,200 identical rows, every one redundant.

Note: estimates based on `statements_top_n = 50` (the configurable collection
limit) significantly understate the problem. The relevant ceiling is
`pg_stat_statements.max = 5000` — the number of distinct queryids PostgreSQL
tracks, regardless of how many are collected per tick.

**The problem has two independent axes that compound each other:**

1. **Redundant inserts** — storing identical rows every minute when nothing changed
2. **DELETE-based retention** — generating millions of dead tuples per cleanup cycle

Both must be fixed. Fixing only one halves the problem at best.

**The hot ring buffers have a correctness problem, not a volume problem.** Dead
tuples from UPDATE-based overwrite on UNLOGGED tables are real but the total
affected volume is under 20 MiB. Important to fix, but not the storage crisis.

---

## 4. Root Cause

Every snapshot child table is a plain LOGGED heap table with append-only inserts
and DELETE-based retention. The `cleanup()` function runs:

```sql
delete from pgfr_record.snapshots where captured_at < v_cutoff;
-- cascades to some children; others use separate DELETE statements:

delete from pgfr_record.statement_snapshots
where snapshot_id in (
    select id from pgfr_record.snapshots where captured_at < v_cutoff
);
-- repeated for table_snapshots, index_snapshots, config_snapshots, ...
```

At 30-day retention with 5,000 queryids:

- 216,000,000 rows potentially deleted from `statement_snapshots` in one transaction
- All become dead tuples simultaneously
- Autovacuum must reclaim tens of gigabytes of bloat per cycle
- The correlated subquery performs a sequential scan of the full table on every run
- On a busy server, autovacuum may never catch up — bloat compounds indefinitely

Additionally, `statement_snapshots` is not cleaned via FK cascade — it uses a
separate DELETE with an independent cutoff that can differ from the parent's cutoff.
Parent and child can drift out of sync, leaving orphaned rows that no cleanup pass
ever removes.

---

## 5. Sparse Storage: Store Only What Changed

### 5.1 The config_snapshots model (already implemented)

The upstream `_collect_config_snapshot()` function:

1. On the first snapshot: stores all tracked parameters (~65 rows)
2. On every subsequent snapshot: compares current `pg_settings` against the most
   recent stored values via `DISTINCT ON (name) ORDER BY snapshot_id DESC`
3. Inserts only rows where `setting`, `source`, or `sourcefile` changed

In a stable environment this produces very few rows after the initial snapshot.
Whether "very few" means dozens or thousands in real deployments has not yet been
measured — see §9.2. This is the template for all other tables.

### 5.2 Apply to `statement_snapshots` (PGSS)

`pg_stat_statements` exposes cumulative counters: `calls`, `total_exec_time`,
`rows`, `shared_blks_hit`, etc. A query that has not been called since the last
snapshot has identical counter values. There is no reason to store another row.

**Insert condition:** store a new row for `(queryid, dbid, userid)` only when
`calls` has increased since the last stored row for that combination within the
current day's partition.

```sql
-- in _collect_statement_snapshot():
with latest as (
    select distinct on (queryid, dbid, userid)
        queryid, dbid, userid, calls
    from pgfr_record.statement_snapshots
    where captured_at >= current_date  -- today's partition only
    order by queryid, dbid, userid, captured_at desc
)
insert into pgfr_record.statement_snapshots (...)
select ...
from pg_stat_statements pss
left join latest l using (queryid, dbid, userid)
where
    l.queryid is null        -- first appearance today (baseline)
    or pss.calls > l.calls   -- query was called
    or pss.calls < l.calls;  -- calls dropped: pg_stat_reset() occurred
```

**Partition boundary guarantee:** at the start of each new day's partition, store
a full baseline row for every tracked queryid currently in `pg_stat_statements`.
This ensures point-in-time reads never need to look back more than one partition.

**Reset detection:** when `calls` drops between snapshots, `pg_stat_reset()` was
called. Always store the post-reset row — it marks the reset boundary for readers.

**Expected reduction:** on a typical server with 5,000 tracked queries, 50–200
queries fire on any given minute tick. The sparse model inserts 50–200 rows
instead of 5,000 — a 25–100× reduction per tick. Over 30 days (assuming ~280
bytes/row based on schema analysis — to be confirmed by §9.2 baseline measurement):

| Scenario | Rows/day | ~MiB/day | vs naive |
|----------|----------|----------|---------|
| Naive (full insert) | 7,200,000 | ~2,024 | baseline |
| Sparse — heavy OLTP (200 active/tick) | ~290,000 | ~81 | ~25× better |
| Sparse — typical OLTP (50 active/tick) | ~75,000 | ~21 | ~96× better |
| Sparse — idle (0 active/tick) | 5,000 (baseline only) | ~1.4 | ~1,400× better |

### 5.3 Apply to `table_snapshots` and `index_snapshots`

`pg_stat_user_tables` exposes cumulative counters. A table that has not been
touched since the last snapshot has identical values.

**Insert condition:** store a new row only when any tracked counter changed.
The cheapest sentinel: `seq_scan + idx_scan + n_tup_ins + n_tup_upd + n_tup_del`.
If this sum is unchanged and `n_dead_tup`, `last_vacuum`, `last_autovacuum` are
also unchanged — skip the row.

Same partition boundary guarantee applies: full baseline row per relation at the
start of each day's partition.

**Expected reduction:** the long tail of static tables (reference tables, infrequently
written application tables, system catalogs) produces no rows after the daily
baseline. Reduction: 3–10× vs naive model depending on table activity distribution.

### 5.4 What NOT to apply sparse storage to

| Table | Reason |
|-------|--------|
| `snapshots` (parent) | Low volume (1 row/min), serves as the master timeline anchor |
| `replication_snapshots` | Low volume; replication state changes matter even when counters are stable |
| `vacuum_progress_snapshots` | Only populated during active vacuum — already sparse by nature |
| Archive and ring buffer tables | Written from ring flush or ring sampling — different collection path |

---

## 6. Reader Functions for Sparse Data

With sparse storage, reader functions must reconstruct the full picture at any
requested timestamp. The storage model is invisible to the consumer — functions
handle reconstruction internally.

### 6.1 Partition boundary guarantee simplifies readers

Because every sparse table has a full baseline row at the start of each daily
partition, any point-in-time read needs to look back at most one partition
boundary. Reconstruction cost is O(log n) per queryid or relid — a single index
scan on `(queryid, captured_at DESC)`.

### 6.2 Required reader patterns

Three read patterns cover all use cases:

**Point-in-time state** — full state of all objects at timestamp T.
Use `DISTINCT ON (queryid, dbid, userid) ORDER BY queryid, dbid, userid, captured_at DESC WHERE captured_at <= T`.
The partition boundary baseline guarantees a result within one partition.

**Interval activity** — what was active between T1 and T2.
For cumulative counters: `latest_value - earliest_value` within the window.
Exclude queryids where the latest `calls` equals the earliest (no activity).
Handle resets: when `calls` drops within the window, the counter was reset —
either exclude the interval or surface it as a reset event.

**Change history** — when did a value change and what did it change to.
For config: every stored row is a change event. Return rows ordered by
`captured_at` within the requested window.

### 6.3 Key constraint: `set jit = off`

All reader functions must include `set jit = off`. JIT compilation adds significant
overhead to the first query in a fresh session on OLTP servers — exactly when
these functions are used during incidents.

---

## 7. Proposed Solution: N Daily Partitions, No DELETE

### 7.1 Partition structure

Partition every table by day using `partition by range (captured_at)`. Retention =
N days = N partitions. Drop the oldest partition when it falls outside the
retention window. No DELETE. No dead tuples. No autovacuum pressure from retention.

```sql
create table pgfr_record.statement_snapshots (
    snapshot_id  integer not null,
    captured_at  timestamptz not null,  -- denormalized from snapshots at insert time
    queryid      bigint not null,
    ...
) partition by range (captured_at);

create table pgfr_record.statement_snapshots_2026_02_26
    partition of pgfr_record.statement_snapshots
    for values from ('2026-02-26') to ('2026-02-27');
```

The `captured_at` column is denormalized into each child table. This makes each
table self-contained for retention — no join back to the parent required.

### 7.2 Partition pre-creation and drop

```sql
-- create tomorrow's partition (run nightly via pg_cron):
select pgfr_record._ensure_partition('statement_snapshots', current_date + 1);

-- drop partitions outside the retention window (run nightly):
select pgfr_record.drop_old_partitions();
```

`_ensure_partition()` is idempotent — safe to call multiple times for the same
date. `drop_old_partitions()` iterates over all `pgfr_record` tables with a
`_YYYY_MM_DD` suffix and drops any whose date falls before the retention cutoff.

### 7.3 Hot ring buffers: TRUNCATE rotation

The ring buffers (`wait_samples_ring`, `activity_samples_ring`, `lock_samples_ring`)
have a different but related problem: UPDATE-based overwrite on UNLOGGED tables
generates dead tuples on every sample cycle. The fix is 3-partition TRUNCATE
rotation with INSERT-only writes — identical to the pg_ash approach.

```
partition_0 (previous) | partition_1 (current, inserting) | partition_2 (truncated, next)
```

At rotation: advance the current slot, TRUNCATE the "next" partition. Zero dead
tuples. No semantic change to the ring window or reader behavior.

### 7.4 Scope of partition-based retention

All tables receive the same treatment. Phases determined by volume and impact:

| Table | Fix | Phase |
|-------|-----|-------|
| `statement_snapshots` | Sparse insert + daily partitions | 1 |
| `config_snapshots` | Daily partitions (sparse insert already done) | 1 |
| `table_snapshots`, `index_snapshots` | Sparse insert + daily partitions | 2 |
| `snapshots`, `replication_snapshots`, others | Daily partitions | 2 |
| Archive tables | Daily partitions | 3 |
| Hot ring buffers | TRUNCATE rotation | 3 |

---

## 8. Retention Model

Each data tier has one canonical retention config key. N days retention = N daily
partitions, oldest dropped nightly.

| Config key | Default | Min | Max | Covers |
|------------|---------|-----|-----|--------|
| `retention_snapshots_days` | 30 | 1 | 365 | All snapshot-tier tables |
| `retention_archive_days` | 7 | 1 | 90 | Archive and aggregate tables |
| `retention_hot_hours` | 4 | 2 | 168 | Hot ring — rotation period, not partition drop |

Old config keys (`aggregate_retention_days`, `archive_retention_days`,
`retention_samples_days`) remain as deprecated aliases until removed in a later
phase.

---

## 9. Benchmarking and Testing

The benchmark suite has two goals: prove correctness (reader output is identical
to the old schema for any given time window) and prove superiority (zero bloat,
orders-of-magnitude storage reduction) under realistic and extreme conditions.

Both old and new schemas run side by side on identical hardware with identical
workloads. Results are published to `benchmarks/` in the repository.

See also: https://github.com/dventimisupabase/pg-flight-recorder/pull/13 for
prior benchmarking context.

### 9.1 Test environment

Dedicated server — AMD EPYC or equivalent, 8 vCPU, 16 GiB RAM. No shared or
burstable instances.

```
shared_buffers = '4GB'
max_connections = 200
autovacuum = on
autovacuum_vacuum_cost_delay = 2ms
pg_stat_statements.max = 5000       -- the PostgreSQL default; non-negotiable
```

PostgreSQL 17, pg_cron 1.6.

### 9.2 Baseline measurement — actual row counts and sizes (run first)

**Goal:** Replace the estimated numbers in Section 3 with observed values from
the benchmark environment. All figures in the storage analysis table are currently
derived from schema inspection and row-count arithmetic. They must be validated
against a running installation before any optimization work begins.

Run pg-flight-recorder at default configuration for 24 hours, then measure:

```sql
-- Actual row counts
select
    schemaname,
    relname,
    n_live_tup,
    n_dead_tup,
    pg_size_pretty(pg_relation_size(relid))       as heap_size,
    pg_size_pretty(pg_total_relation_size(relid)) as total_size,
    pg_relation_size(relid) / nullif(n_live_tup, 0) as bytes_per_row
from pg_stat_user_tables
where schemaname = 'pgfr_record'
order by pg_total_relation_size(relid) desc;
```

```sql
-- Collection latency per section (from collection_stats)
select
    section_name,
    avg(duration_ms)  as avg_ms,
    max(duration_ms)  as max_ms,
    count(*)          as samples
from pgfr_record.collection_stats
where captured_at > now() - interval '1 hour'
group by section_name
order by avg_ms desc;
```

```sql
-- Actual rows inserted per hour (run after 24h of collection)
select
    date_trunc('hour', captured_at) as hour,
    count(*)                         as rows_inserted
from pgfr_record.statement_snapshots
group by 1
order by 1;
```

Record for each table:
- Actual rows after 24h
- Actual bytes/row (heap_size / n_live_tup)
- Actual rows inserted per tick (from collection stats or direct count)

Update the Section 3 table with observed values before proceeding to any
optimization benchmarks. The estimates there are based on schema analysis;
real numbers may differ — especially `bytes_per_row` for TOAST-heavy columns
like `query_preview TEXT` in `statement_snapshots`.

### 9.3 Sparse storage reduction benchmark (Phase 1 focus)

**Goal:** Quantify how much sparse collection reduces row count vs the naive
full-insert model. The benchmark must use `pg_stat_statements.max = 5000` —
this is where the reduction is most dramatic and most representative.

**Setup:** generate exactly 5,000 distinct queryids to fill `pg_stat_statements`:

```bash
python3 -c "
for i in range(1, 5001):
    print(f'SELECT {i} AS n;')
" > /tmp/fill_pgss.sql

psql -f /tmp/fill_pgss.sql postgres > /dev/null
psql -c "select count(*) from pg_stat_statements;"
-- expected: 5000
```

Run under four workload profiles, each for 24 hours:

| Profile | Active queries per tick | Expected rows/tick (sparse) | vs naive (5,000/tick) |
|---------|------------------------|-----------------------------|-----------------------|
| Idle | 0 | 5,000 (baseline only, once/day) | ~99.9% reduction |
| Typical OLTP | ~50 | ~50 | ~99% reduction |
| Heavy OLTP | ~200 | ~200 | ~96% reduction |
| Adversarial (all active) | ~5,000 | ~5,000 | ~0% — proves graceful degradation |

The adversarial profile confirms the sparse model never performs worse than naive.
The `DISTINCT ON` lookup overhead must not add unacceptable latency.

**Measure every hour:**

```sql
select
    'new (sparse)' as schema,
    date_trunc('hour', captured_at) as hour,
    count(*) as rows_inserted
from pgfr_record.statement_snapshots
group by 2
union all
select
    'old (naive)',
    date_trunc('hour', s.captured_at),
    count(*)
from pgfr_record_old.statement_snapshots ss
join pgfr_record_old.snapshots s on s.id = ss.snapshot_id
group by 2
order by 1, 2;
```

### 9.4 Simulated long-run bloat benchmark

**Goal:** Show what happens to the old schema under sustained operation across
multiple retention cycles — the scenario that causes production bloat — and confirm
the new schema is immune.

Real 30-day runs are impractical. Simulate by compressing time: short retention
window (1 hour) with continuous `snapshot()` + `cleanup()` in a loop for 2 hours
= 2 full retention cycles.

```sql
update pgfr_record.config set value = '0.04' where key = 'retention_snapshots_days';
-- 0.04 days ≈ 1 hour retention
```

```bash
# old schema:
pgbench -c 1 -j 1 -T 7200 \
  -f <(echo "select pgfr_record.snapshot(); select pgfr_record.cleanup();") postgres

# new schema:
pgbench -c 1 -j 1 -T 7200 \
  -f <(echo "select pgfr_record.snapshot(); select pgfr_record.drop_old_partitions();") postgres
```

Measure every 15 minutes:

```sql
select
    now() as measured_at,
    schemaname,
    relname,
    n_live_tup,
    n_dead_tup,
    pg_size_pretty(pg_total_relation_size(relid)) as total_size
from pg_stat_user_tables
where schemaname in ('pgfr_record', 'pgfr_record_old')
  and relname like '%statement%'
order by schemaname, relname;
```

Expected:

| Metric | Old schema (DELETE) | New schema (partition DROP) |
|--------|--------------------|-----------------------------|
| `n_dead_tup` after cleanup | = rows deleted | 0 always |
| Heap size trend | Growing | Flat |
| Autovacuum runs per hour | Many | 0 from retention |
| Cleanup duration trend | Growing with bloat | Constant |

### 9.5 Extreme bloat: autovacuum disabled

The real production failure mode: autovacuum throttled or falling behind on a
heavily loaded server.

```sql
alter table pgfr_record_old.statement_snapshots set (autovacuum_enabled = false);
```

Run the same 2-hour simulation (§9.4). Expected: heap grows unboundedly in the old
schema (2–5× live data size after 2 hours). New schema: zero dead tuples, no heap
growth beyond live data.

### 9.6 Cleanup duration scaling

Measure at three data volumes: 1 day, 7 days, 30 days of accumulated data.

Expected scaling:

| Volume | Old schema DELETE | New schema DROP |
|--------|------------------|-----------------|
| 1 day | ~500 ms | < 50 ms |
| 7 days | ~3 s | < 50 ms |
| 30 days | ~15–30 s | < 50 ms |

Partition DROP is O(1) with respect to row count. DELETE is O(n).

### 9.7 Cleanup impact on concurrent `snapshot()` latency

A large DELETE holds a relation lock and generates WAL, which can cause concurrent
`snapshot()` calls to wait. Run both operations concurrently and capture `snapshot()`
durations from `collection_stats` before, during, and after cleanup.

Expected for old schema: latency spike during DELETE. Expected for new schema:
`drop_old_partitions()` is near-instantaneous and `snapshot()` is unaffected.

### 9.8 `snapshot()` latency regression test

Confirm no regression in collection latency after migration. Run 50 calls, record
median and p99. Expected: no regression — the sparse insert adds one `DISTINCT ON`
lookup per tick, which must complete in under 5 ms at 5,000 queryids.

### 9.9 Reader correctness and partition pruning

**Correctness:** for any time window, reader output must be identical between old
and new schema. Verify for point-in-time reads, interval activity, and edge cases
(reset events, first and last row of a partition).

**Partition pruning:** verify via `explain (analyze)` that time-bounded queries
eliminate irrelevant partitions:

```sql
explain (analyze, buffers)
select count(*)
from pgfr_record.statement_snapshots
where captured_at > now() - interval '1 hour';
-- expect: "Partitions selected: 1 out of N"
```

Old schema has no partitioning — every time-bounded query scans the full table.

### 9.10 `pg_stat_reset()` handling

Trigger 10 resets over 1 hour while collecting. Verify reader functions return
non-negative delta values and correctly identify reset boundaries. No negative
`calls_delta` values should be surfaced to callers.

### 9.11 pgTAP regression suite

All existing tests must pass without modification. New tests for Phase 1:

- `_ensure_partition()` is idempotent
- `snapshot()` routes to the correct daily partition
- `drop_old_partitions()` drops exactly the partitions outside the retention window
- Sparse insert: rows skipped when `calls` unchanged; rows stored when `calls` increases
- Partition boundary baseline: first row of each day covers all active queryids
- `n_dead_tup = 0` on all partitions after `drop_old_partitions()`
- Reader output matches old schema for the same time window
- Partition pruning confirmed via `explain` for 1-hour time-bounded queries

---

## 10. Open Questions

**Q1: FK from child tables to `snapshots` after partitioning.**
PostgreSQL 15+ supports FKs referencing partitioned tables. When a `snapshots`
partition is dropped, cascade fires for rows in that partition — but only if the
child tables are also partitioned with aligned boundaries. Alternatively: drop the
FK and enforce integrity at the collection layer. Evaluate in Phase 2 when
`snapshots` itself is partitioned.

**Q2: Migration for existing installations.**
Converting a plain heap table to a partitioned table requires rename + create +
copy + drop. At tens of millions of rows, the copy step requires a maintenance
window. Zero-downtime migration (dual-write + backfill + cutover) is possible but
significantly more complex. Evaluate based on target deployment size.

**Q3: Sparse insert overhead at 5,000 queryids.**
The `DISTINCT ON` lookup within today's partition is bounded by the partition size
(at most one day of data) and uses the `(queryid, captured_at)` index. At 5,000
queryids and 1-minute intervals, the partition contains at most 5,000 × 1,440 =
7.2M rows in the worst case — still within the range where an index scan is fast.
Measure in §9.8 and tune the index if needed.

**Q4: Managed provider compatibility.**
Partitioned tables, `drop table`, and pg_cron are supported on RDS, Cloud SQL,
Supabase, and Neon. The daily partition pre-creation and drop jobs require pg_cron
scheduling rights. No superuser required for partition management after initial
install.
