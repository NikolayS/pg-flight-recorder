# Storage Overhaul: Partition-Based Retention, Zero DELETE

| Version | Date | Author |
|---------|------|--------|
| 1.0 | 2026-02-26 | @NikolayS |

---

## Table of Contents

1. [Background and Motivation](#1-background-and-motivation)
2. [Scope and Constraints](#2-scope-and-constraints)
3. [Storage Analysis: Where the Problem Actually Is](#3-storage-analysis-where-the-problem-actually-is)
4. [Root Cause](#4-root-cause)
5. [Proposed Solution: N Daily Partitions, No DELETE](#5-proposed-solution-n-daily-partitions-no-delete)
6. [Retention Model](#6-retention-model)
7. [Table-by-Table Plan](#7-table-by-table-plan)
8. [Implementation Phases](#8-implementation-phases)
9. [Implementation Steps](#9-implementation-steps)
10. [Success Criteria](#10-success-criteria)
11. [Benchmarking and Testing](#11-benchmarking-and-testing)
12. [Open Questions](#12-open-questions)

---

## 1. Background and Motivation

pg-flight-recorder records comprehensive PostgreSQL telemetry continuously via
pg_cron — wait events, active sessions, lock contention, WAL activity, checkpoints,
I/O, table and index statistics, query performance (`pg_stat_statements`),
replication state, and configuration. The data accumulates in a set of LOGGED tables
with DELETE-based retention managed by periodic `cleanup()` calls.

At default configuration (1-minute snapshot interval, 30-day retention, top 50
queries and tables per snapshot), the total storage footprint reaches approximately
2.6 GiB — and every `cleanup()` run generates that same volume as dead tuples in a
single transaction, leaving autovacuum to reclaim gigabytes of bloat per cycle.

This document describes a storage redesign that eliminates DELETE-based retention
entirely, replacing it with daily time-based partitioning and partition DROP across
all tables. No functional changes. No semantic changes. No changes to what is
collected, at what frequency, or what the reader functions return.

---

## 2. Scope and Constraints

### What this overhaul does

- Replace DELETE-based retention with partition DROP across all tables
- Introduce N daily partitions where N = configured retention in days
- Eliminate all dead tuples from retention operations
- Make retention configurable per data tier, with sensible defaults
- Restructure the hot ring buffers to use TRUNCATE rotation (zero dead tuples
  from the sampling path itself)

### What this overhaul does NOT do

- **No semantic changes** — what is collected, at what frequency, and what
  reader functions return remains identical
- **No new columns** — no `query_id`, no additional metrics
- **No frequency changes** — snapshot intervals stay as configured
- **No changes to `pgfr_analyze` or `pgfr_control`** — out of scope
- **No changes to collection logic** — circuit breaker, load shedding,
  section timeouts, `snapshot_based_collection` all preserved as-is

---

## 3. Storage Analysis: Where the Problem Actually Is

At default configuration (1-minute snapshots, top 50 queries/tables, 30-day
retention), estimated storage per table:

| Table | Rows at retention | ~MiB | Insert rate | Priority |
|-------|-------------------|------|-------------|----------|
| `config_snapshots` | 8,640,000 | 1,046 | 200 params × 1/min | **P0** |
| `statement_snapshots` | 2,160,000 | 608 | 50 queries × 1/min | **P0** |
| `table_snapshots` | 2,160,000 | 552 | 50 tables × 1/min | **P0** |
| `index_snapshots` | 2,160,000 | 262 | 50 indexes × 1/min | **P0** |
| `db_role_config_snapshots` | 432,000 | 44 | ~10 × 1/min | **P1** |
| `activity_samples_archive` | 168,000 | 37 | 25 × 4/hr | **P1** |
| `snapshots` (parent) | 43,200 | 23 | 1/min | **P1** |
| `replication_snapshots` | 86,400 | 15 | ~2 × 1/min | **P1** |
| `wait_samples_ring` | 12,000 (fixed) | 1.5 | UPDATE overwrite | **P2** |
| `lock_samples_ring` | 12,000 (fixed) | ~7 (bloated) | UPDATE overwrite | **P2** |
| `activity_samples_ring` | 3,000 (fixed) | ~2 (bloated) | UPDATE overwrite | **P2** |
| `wait_event_aggregates` | 40,320 | 6 | ~20 × 12/hr | **P2** |
| `wait_samples_archive` | 13,440 | 2 | 20 × 4/hr | **P2** |
| **Total** | | **~2,600** | | |

### Key finding

The snapshot tier (`config_snapshots`, `statement_snapshots`, `table_snapshots`,
`index_snapshots`) accounts for **95% of total storage**. The ring buffers that
were the initial focus of this document are less than 1% of the problem by volume.

The hot ring buffers have a correctness problem (UPDATE-based overwrite generates
dead tuples in UNLOGGED tables), but not a volume problem. The snapshot tier has
both: enormous volume and catastrophic DELETE behavior at cleanup time.

---

## 4. Root Cause

Every snapshot child table (`statement_snapshots`, `table_snapshots`,
`index_snapshots`, `config_snapshots`, `replication_snapshots`,
`vacuum_progress_snapshots`, `db_role_config_snapshots`) is:

1. **A plain LOGGED heap table** — no partitioning
2. **Append-only during normal operation** — inserts only, no updates
3. **Retention via DELETE** — `cleanup()` deletes rows older than N days

The `cleanup()` function runs:

```sql
delete from pgfr_record.snapshots where captured_at < v_cutoff;
-- cascades to: replication_snapshots, vacuum_progress_snapshots
-- (but NOT to statement_snapshots, table_snapshots, index_snapshots,
--  config_snapshots, db_role_config_snapshots — these run separate DELETEs)

delete from pgfr_record.statement_snapshots
where snapshot_id in (
    select id from pgfr_record.snapshots where captured_at < v_cutoff
);
-- ...and so on for each child table
```

At 30-day retention this means:

- 2,160,000 rows deleted from `statement_snapshots` in one transaction
- 2,160,000 rows deleted from `table_snapshots`
- 8,640,000 rows deleted from `config_snapshots`
- All become dead tuples simultaneously
- Autovacuum must reclaim ~2.5 GiB of bloat per cleanup cycle
- The correlated subquery `snapshot_id in (select id from snapshots ...)`
  performs a sequential scan of each multi-million-row child table on every run

On a busy server, autovacuum may never catch up. Bloat compounds indefinitely.

Additionally, `statement_snapshots` is not cleaned via FK cascade — it uses a
separate DELETE with an independent cutoff (`v_statements_cutoff`), which can
differ from `v_snapshots_cutoff`. Parent and child can drift out of sync,
leaving orphaned child rows that no cleanup pass ever removes.

---

## 5. Proposed Solution: N Daily Partitions, No DELETE

Partition every table by day. Retention = N days = N partitions. Drop the oldest
partition when it falls outside the retention window. No DELETE. No dead tuples.
No autovacuum pressure from retention operations.

### Partition key

Use `captured_at::date` (or `snapshot_id` routed via date) as the partition key
for all tables. Partition by `range` on `captured_at`:

```sql
-- example: statement_snapshots partitioned by day
create table pgfr_record.statement_snapshots (
    snapshot_id  integer not null,
    captured_at  timestamptz not null,  -- denormalized from snapshots for partition key
    queryid      bigint not null,
    ...
) partition by range (captured_at);

create table pgfr_record.statement_snapshots_2026_02_26
    partition of pgfr_record.statement_snapshots
    for values from ('2026-02-26') to ('2026-02-27');
```

The `captured_at` column is denormalized into each child table. This removes the
dependency on joining back to `snapshots` for retention, and makes the partition
key self-contained.

### Retention operation

```sql
create or replace function pgfr_record.drop_old_partitions()
returns void language plpgsql as $$
declare
    v_retention_days integer;
    v_cutoff         date;
    v_partition      text;
begin
    v_retention_days := pgfr_record._get_config('retention_snapshots_days', '30')::integer;
    v_cutoff := current_date - v_retention_days;

    for v_partition in
        select tablename
        from pg_tables
        where schemaname = 'pgfr_record'
          and tablename ~ '_\d{4}_\d{2}_\d{2}$'
          and to_date(right(tablename, 10), 'YYYY_MM_DD') < v_cutoff
    loop
        execute format('drop table pgfr_record.%I', v_partition);
    end loop;
end;
$$;
```

Schedule via pg_cron: once daily, after midnight.

### Partition creation

Partitions are created ahead of time by `enable()` and by a daily pg_cron job:

```sql
create or replace function pgfr_record._ensure_partition(
    p_table text,
    p_date  date
)
returns void language plpgsql as $$
declare
    v_name text;
begin
    v_name := p_table || '_' || to_char(p_date, 'YYYY_MM_DD');
    execute format(
        'create table if not exists pgfr_record.%I
         partition of pgfr_record.%I
         for values from (%L) to (%L)',
        v_name, p_table, p_date, p_date + 1
    );
end;
$$;
```

Called for `today` and `today + 1` (pre-create tomorrow's partition at midnight).

### Hot ring buffers

The ring buffers (`wait_samples_ring`, `activity_samples_ring`, `lock_samples_ring`)
have a different problem: UPDATE-based overwrite on UNLOGGED tables generates dead
tuples on every sample cycle. The fix is TRUNCATE-rotation with 3 UNLOGGED partitions
and INSERT-only writes — identical to the pg_ash approach. No semantic change: the
ring still holds the same window of recent data.

```
partition_0 (previous) | partition_1 (current, inserting) | partition_2 (truncated, next)
```

At rotation: advance slot, TRUNCATE the "next" partition. Zero dead tuples. Zero bloat.

---

## 6. Retention Model

Each data tier has one canonical retention config key. N days of retention = N
daily partitions kept, oldest dropped by the daily cleanup job.

| Config key | Default | Min | Max | Covers |
|------------|---------|-----|-----|--------|
| `retention_snapshots_days` | 30 | 1 | 365 | `snapshots`, `statement_snapshots`, `table_snapshots`, `index_snapshots`, `config_snapshots`, `replication_snapshots`, `vacuum_progress_snapshots`, `db_role_config_snapshots` |
| `retention_archive_days` | 7 | 1 | 90 | `wait_samples_archive`, `lock_samples_archive`, `activity_samples_archive`, `wait_event_aggregates`, `lock_aggregates`, `activity_aggregates` |
| `retention_hot_hours` | 4 | 2 | 168 | Hot ring — controls rotation period (no DELETE, no partition drop) |

All children in the snapshot tier share one retention value. Their partitions are
aligned by day, so dropping one day's partitions across all tables is a single
coordinated operation.

Old config keys (`aggregate_retention_days`, `archive_retention_days`,
`retention_samples_days`) remain as deprecated aliases in the `config` table,
mapping to the new canonical keys. They are removed in Phase 3.

---

## 7. Table-by-Table Plan

### 7.1 Snapshot tier — partition by day, DROP for retention

All tables in the snapshot tier receive the same treatment:

1. Add `captured_at timestamptz not null` as a denormalized column (where not
   already present — most children currently have only `snapshot_id`)
2. Convert to `partition by range (captured_at)`
3. Pre-create partitions in `enable()` and daily via pg_cron
4. Drop oldest partition in daily `drop_old_partitions()` job
5. Remove the corresponding DELETE block from `cleanup()`

Tables in scope:

| Table | Currently has `captured_at`? | Notes |
|-------|------------------------------|-------|
| `snapshots` | Yes | Parent — partition key already present |
| `statement_snapshots` | No — has `snapshot_id` FK | Add `captured_at`, denormalize from `snapshots` at insert time |
| `table_snapshots` | No | Same |
| `index_snapshots` | No | Same |
| `config_snapshots` | No | Same |
| `replication_snapshots` | No | Same |
| `vacuum_progress_snapshots` | No | Same |
| `db_role_config_snapshots` | No | Same |

The FK from child to `snapshots(id)` is retained for relational integrity within
a given day's partition. Cascade behavior becomes irrelevant — retention is managed
by partition DROP, not by cascading DELETE.

### 7.2 Archive tier — partition by day, DROP for retention

`wait_samples_archive`, `lock_samples_archive`, `activity_samples_archive` already
have `captured_at`. Convert to `partition by range (captured_at)`.

`wait_event_aggregates`, `lock_aggregates`, `activity_aggregates` have `start_time`.
Use `start_time` as partition key.

Retention: `retention_archive_days` (default 7 days = 7 partitions).

### 7.3 Hot ring tier — TRUNCATE rotation, 3 UNLOGGED partitions

`wait_samples_ring`, `activity_samples_ring`, `lock_samples_ring`, `samples_ring`

Replace the pre-populated UPDATE-overwrite pattern with a 3-partition TRUNCATE
rotation. The partition key is `slot smallint` with values in `{0, 1, 2}`.

```
partition_0 | partition_1 | partition_2
 previous   |   current   |    next
 read-only  |  inserting  |  truncated
```

Rotation: advance `current_slot`, TRUNCATE the partition two slots ahead.
Schedule via pg_cron at `rotation_period = retention_hot_hours / 2`.

No semantic change: the ring window covers the same time span. Reader views
query the current and previous partitions.

### 7.4 `collection_stats` — leave as-is

UNLOGGED, low row volume (~1 row per sample tick, deleted by `cleanup()` after
30 days). At ~1,440 rows/day × 30 days = 43,200 rows × 117 bytes = 4.8 MiB.
The DELETE is trivial at this scale. No change required.

---

## 8. Implementation Phases

Work proceeds from highest-impact to broadest coverage. Each phase is independently
deployable and must be fully tested and benchmarked before the next phase begins.

### Phase 1 — `statement_snapshots` (proof of concept)

**Why first:** Second largest by volume (608 MiB), highest operational value
(PGSS data is the most actionable telemetry in the system), representative of the
entire snapshot child pattern. Proving the solution here validates the approach
for all other tables.

**Scope:** `statement_snapshots` only.

**Deliverables:**

- Add `captured_at timestamptz not null` to `statement_snapshots`
- Convert to `partition by range (captured_at)`
- Create initial partitions in `install.sql` (today + tomorrow)
- Add `_ensure_partition(table, date)` function
- Add `drop_old_partitions()` function (covers `statement_snapshots` only for now)
- Update `snapshot()` collection function to populate `captured_at` at insert time
- Update `cleanup()` to skip the `statement_snapshots` DELETE block
- Update reader views and functions in `pgfr_analyze` that join `statement_snapshots`
- pgTAP tests for partition creation, rotation, drop, and reader correctness

**Does not include:** Any other table. No changes to `snapshots` parent,
`table_snapshots`, `index_snapshots`, or ring buffers.

**Exit criteria:** Full benchmark results demonstrating zero dead tuples after
cleanup cycle, correct reader output, and no regression on existing tests.

---

### Phase 2 — Snapshot tier completion

**Why after Phase 1:** The pattern is validated. Apply it to all remaining snapshot
children.

**Scope:** `snapshots` (parent), `table_snapshots`, `index_snapshots`,
`config_snapshots`, `replication_snapshots`, `vacuum_progress_snapshots`,
`db_role_config_snapshots`.

**Deliverables:**

- Partition `snapshots` by `captured_at` — this is the parent; partitioning it
  means child FKs must point to the correct partition. Evaluate whether to keep the
  FK or drop it (FK across partitioned tables requires careful handling in PG15+).
- For each child: add `captured_at`, convert to partitioned, update insert path,
  update `drop_old_partitions()`
- Coordinate partition names across parent and all children (same date suffix)
- Update `cleanup()` to remove all remaining DELETE blocks for snapshot tier
- Update `retention_snapshots_days` as the single control for all snapshot partitions
- Full regression test suite across all tables

**Exit criteria:** Same as Phase 1. All snapshot tier tables covered. `cleanup()`
contains no DELETE statements for the snapshot tier.

---

### Phase 3 — Archive tier + hot ring

**Why last:** Lower volume, lower urgency. Hot ring has a correctness issue (dead
tuples from UPDATE) but not a volume issue.

**Scope:** Archive tables (`wait_samples_archive`, `lock_samples_archive`,
`activity_samples_archive`, `wait_event_aggregates`, `lock_aggregates`,
`activity_aggregates`) and hot ring (`wait_samples_ring`, `activity_samples_ring`,
`lock_samples_ring`, `samples_ring`).

**Deliverables:**

**Archive tables:**

- Convert to `partition by range (captured_at)` or `start_time`
- Add to `drop_old_partitions()` under `retention_archive_days`
- Remove DELETE blocks from `cleanup_aggregates()`

**Hot ring:**

- Replace `wait_samples_ring`, `activity_samples_ring`, `lock_samples_ring`,
  `samples_ring` with 3-partition UNLOGGED tables
- Implement `rotate_ring()` with TRUNCATE pattern
- Update `sample()` to INSERT-only (no null-out UPDATE)
- Update `flush_ring_to_aggregates()` and `archive_ring_samples()` to read from
  new ring tables
- Reimplement `recent_waits`, `recent_activity`, `recent_locks` reader views
  (same output columns)

**Exit criteria:** Zero dead tuples across all tables after 24 hours of operation.
Full regression test suite passing.

---

### Phase 4 — Polish and cleanup

**Scope:** Reader performance, deprecated config key removal, documentation.

**Deliverables:**

- Add `set jit = off` to all reader functions in `pgfr_record` and `pgfr_analyze`
- Remove deprecated config key aliases (`aggregate_retention_days`,
  `archive_retention_days`, `retention_samples_days`)
- Add `pgfr_record.storage_estimate()` function — projects storage per tier based
  on current config and measured row sizes
- Remove `relation_names` table pre-populate step from `cleanup()` (now handled
  at partition creation time)
- Update `REFERENCE.md` and `_record/README.md`
- Final end-to-end benchmark: all tiers, full retention cycle, zero dead tuples

---

## 9. Implementation Steps

### Phase 1 detailed steps

**Step 1: Add `captured_at` to `statement_snapshots`**

```sql
alter table pgfr_record.statement_snapshots
    add column if not exists captured_at timestamptz;
```

For existing rows, backfill from parent:

```sql
update pgfr_record.statement_snapshots ss
set captured_at = s.captured_at
from pgfr_record.snapshots s
where s.id = ss.snapshot_id
  and ss.captured_at is null;
```

**Acceptance test:** All rows have non-null `captured_at`. Value matches parent
`snapshots.captured_at` for the same `snapshot_id`.

**Step 2: Convert to partitioned table**

Since PostgreSQL does not support converting an existing table to a partitioned
table in-place, the migration path is:

```sql
-- rename existing table
alter table pgfr_record.statement_snapshots
    rename to statement_snapshots_old;

-- create new partitioned table with same columns
create table pgfr_record.statement_snapshots (
    snapshot_id         integer not null,
    captured_at         timestamptz not null,
    queryid             bigint not null,
    ...
    primary key (snapshot_id, queryid, dbid, captured_at)
) partition by range (captured_at);

-- create today and tomorrow partitions
select pgfr_record._ensure_partition('statement_snapshots', current_date);
select pgfr_record._ensure_partition('statement_snapshots', current_date + 1);

-- migrate existing data
insert into pgfr_record.statement_snapshots
select * from pgfr_record.statement_snapshots_old;

drop table pgfr_record.statement_snapshots_old;
```

**Acceptance test:** Row counts match before and after migration. `\d+
pgfr_record.statement_snapshots` shows partitioned table with 2 partitions.

**Step 3: `_ensure_partition()` function**

Creates a daily partition if it does not already exist. Idempotent — safe to call
multiple times for the same date.

```sql
create or replace function pgfr_record._ensure_partition(
    p_table text,
    p_date  date
)
returns void language plpgsql as $$
declare
    v_name text;
begin
    v_name := p_table || '_' || to_char(p_date, 'YYYY_MM_DD');
    if not exists (
        select 1 from pg_tables
        where schemaname = 'pgfr_record' and tablename = v_name
    ) then
        execute format(
            'create table pgfr_record.%I
             partition of pgfr_record.%I
             for values from (%L::timestamptz) to (%L::timestamptz)',
            v_name, p_table,
            p_date::timestamptz,
            (p_date + 1)::timestamptz
        );
    end if;
end;
$$;
```

Schedule daily partition pre-creation via pg_cron:

```sql
select cron.schedule(
    'pgfr-ensure-partitions',
    '55 23 * * *',
    $$select pgfr_record._ensure_partition('statement_snapshots', current_date + 1)$$
);
```

**Acceptance test:** Call `_ensure_partition('statement_snapshots', current_date)`
twice — second call is a no-op. Verify partition exists in `pg_tables`.

**Step 4: `drop_old_partitions()` function**

```sql
create or replace function pgfr_record.drop_old_partitions()
returns integer language plpgsql as $$
declare
    v_retention_days integer;
    v_cutoff         date;
    v_partition      text;
    v_dropped        integer := 0;
begin
    v_retention_days := pgfr_record._get_config(
        'retention_snapshots_days', '30'
    )::integer;
    v_cutoff := current_date - v_retention_days;

    for v_partition in
        select tablename
        from pg_tables
        where schemaname = 'pgfr_record'
          and tablename like 'statement_snapshots_%'
          and to_date(right(tablename, 10), 'YYYY_MM_DD') < v_cutoff
        order by tablename
    loop
        execute format('drop table pgfr_record.%I', v_partition);
        v_dropped := v_dropped + 1;
    end loop;

    return v_dropped;
end;
$$;
```

Schedule daily via pg_cron:

```sql
select cron.schedule(
    'pgfr-drop-old-partitions',
    '0 1 * * *',
    'select pgfr_record.drop_old_partitions()'
);
```

**Acceptance test:** Create a partition with a date 31 days ago. Call
`drop_old_partitions()` with `retention_snapshots_days = 30`. Verify partition is
gone. Call again — returns 0, no error.

**Step 5: Update `snapshot()` insert path**

In `pgfr_record.snapshot()`, populate `captured_at` at insert time:

```sql
insert into pgfr_record.statement_snapshots (
    snapshot_id,
    captured_at,  -- add this
    queryid,
    ...
)
select
    v_snapshot_id,
    v_captured_at,  -- from the parent snapshot timestamp
    queryid,
    ...
from pg_stat_statements
...
```

**Acceptance test:** After calling `snapshot()`, verify the new row has
`captured_at` populated and routes to the correct daily partition.

**Step 6: Remove DELETE from `cleanup()`**

```sql
-- remove this block:
with deleted as (
    delete from pgfr_record.statement_snapshots
    where snapshot_id in (
        select id from pgfr_record.snapshots where captured_at < v_statements_cutoff
    )
    returning 1
)
select count(*) into v_deleted_statements from deleted;
```

**Acceptance test:** Call `cleanup()` — returns 0 for `deleted_statements`.
Verify no rows deleted from `statement_snapshots`. Verify old data is removed
only via `drop_old_partitions()`.

**Step 7: pgTAP tests**

New test file: `_record/tests/16_statement_snapshots_partitioning.sql`

- Partition exists for today after `enable()`
- `_ensure_partition()` is idempotent
- `snapshot()` inserts into the correct daily partition
- `drop_old_partitions()` drops partitions older than retention threshold
- `drop_old_partitions()` does not drop partitions within retention window
- Zero dead tuples after `drop_old_partitions()` (check `pg_stat_user_tables`)
- Reader views return identical output before and after migration

---

## 10. Success Criteria

### Correctness

- [ ] All existing pgTAP tests pass without modification (`./test.sh`)
- [ ] Reader views return identical column names, types, and values before and after
- [ ] `captured_at` in child tables matches `snapshots.captured_at` for same `snapshot_id`
- [ ] `_ensure_partition()` is idempotent — safe to call multiple times
- [ ] `drop_old_partitions()` drops exactly the partitions outside the retention window
- [ ] `drop_old_partitions()` does not error when no partitions need dropping
- [ ] `snapshot()` routes new rows to the correct daily partition
- [ ] No orphaned child rows after partition drop (verified by row count consistency)

### Storage and bloat (Phase 1)

- [ ] Zero dead tuples in `statement_snapshots_*` after `drop_old_partitions()` runs
  (verified via `pg_stat_user_tables.n_dead_tup`)
- [ ] No autovacuum activity on `statement_snapshots_*` triggered by retention operations
- [ ] `drop table` on a 30-day-old partition completes in under 100 ms
- [ ] Total `statement_snapshots` storage matches expectation: ~20 MiB per day at 50
  queries/min (1 day's partition)

### Performance

- [ ] `snapshot()` execution time unchanged (p50, p99) compared to pre-migration
- [ ] Reader view query time unchanged — partition pruning engaged for time-range queries
- [ ] `drop_old_partitions()` completes in under 500 ms regardless of partition row count
- [ ] `_ensure_partition()` completes in under 50 ms

### Retention

- [ ] Changing `retention_snapshots_days` takes effect on the next `drop_old_partitions()` run
- [ ] Reducing retention drops the appropriate partitions immediately on next run
- [ ] Increasing retention keeps existing partitions — no data loss

---

## 11. Benchmarking and Testing

### 11.1 Test environment

Dedicated server, consistent hardware — AMD EPYC or equivalent, 8 vCPU, 16 GiB RAM.
No shared or burstable instances.

```
shared_buffers = '4GB'
max_connections = 200
```

PostgreSQL 17, pg_cron 1.6.

### 11.2 Bloat comparison benchmark

Run both old schema (DELETE-based) and new schema (partition DROP) for 24 hours,
then trigger retention cleanup. Measure dead tuples before and after.

```sql
-- before cleanup (old schema):
select
    relname,
    n_live_tup,
    n_dead_tup,
    pg_size_pretty(pg_total_relation_size(relid)) as total_size
from pg_stat_user_tables
where schemaname = 'pgfr_record'
  and relname like 'statement%'
order by relname;

-- trigger cleanup (old: DELETE; new: drop_old_partitions)
-- re-measure immediately after
-- re-measure after autovacuum has run (or VACUUM ANALYZE)
```

Expected for old schema: `n_dead_tup` = rows deleted (up to 72,000 for 1 day at
50 queries/min). Expected for new schema: `n_dead_tup = 0` on all partitions.

### 11.3 Cleanup duration benchmark

```sql
\timing on
-- old schema:
select * from pgfr_record.cleanup();

-- new schema:
select pgfr_record.drop_old_partitions();
```

Run 5 times each. Record median and p99. Expected: partition DROP is at least 10×
faster than DELETE at equivalent row counts.

### 11.4 `snapshot()` latency benchmark

```sql
\timing on
select pgfr_record.snapshot();
-- run 20 times; record median and p99
```

Compare before and after migration. Expected: no regression — the insert path adds
only `captured_at` population, which is a constant-time operation.

### 11.5 Reader query benchmark

```sql
\timing on
-- time-bounded query (should use partition pruning):
select count(*)
from pgfr_record.statement_snapshots
where captured_at > now() - interval '1 hour';

-- full-range query:
select count(*) from pgfr_record.statement_snapshots;
```

Verify via `explain` that partition pruning eliminates irrelevant partitions for
time-bounded queries. Compare query time before and after migration.

### 11.6 Storage growth measurement

Run for 7 days at default config. Measure total storage daily:

```sql
select
    schemaname,
    tablename,
    pg_size_pretty(pg_total_relation_size(schemaname || '.' || tablename)) as size
from pg_tables
where schemaname = 'pgfr_record'
  and tablename like 'statement_snapshots%'
order by tablename;
```

Expected: linear growth capped at `retention_snapshots_days` partitions. No bloat.
Total size = daily size × retention days, with no additional dead tuple overhead.

### 11.7 pgTAP regression suite

All existing tests must pass. New tests in `_record/tests/16_statement_snapshots_partitioning.sql`
as described in §9 Step 7. Add to CI (`test.sh`) with no changes to test harness.

---

## 12. Open Questions

**Q1: FK from child tables to `snapshots` after partitioning.**
PostgreSQL 15+ supports foreign keys referencing partitioned tables, but each child
partition's FK references the parent partitioned table, not a specific partition.
When a `snapshots` partition is dropped, the cascade to child FKs fires for the
rows in that partition. This is correct behavior — but it requires the child tables
to also be partitioned with aligned partition boundaries so the cascade touches only
one child partition at a time.

Alternative: drop the FK from child tables and enforce integrity at the application
(collection) layer instead. Simpler, but loses referential integrity guarantees.
Evaluate in Phase 2 when `snapshots` itself is partitioned.

**Q2: Partition for `snapshots` parent — shared or separate from children.**
If `snapshots` is partitioned by day, child tables partitioned by the same day
boundaries can be aligned. Dropping a day's `snapshots` partition would cascade to
the same day's child partition. This is the cleanest design but requires all
children to be partitioned first (Phase 2 prerequisite).

In Phase 1, `snapshots` remains unpartitioned. Only `statement_snapshots` is
partitioned. The FK from `statement_snapshots` to `snapshots` is retained.

**Q3: Migration for existing installations.**
The rename-create-migrate-drop approach in Step 2 requires a maintenance window for
large tables. At 2.16M rows × 295 bytes, the `INSERT INTO ... SELECT *` migration
takes approximately 30–60 seconds on typical hardware. For zero-downtime migration,
an online approach (create partitioned table, dual-write, backfill, cutover) is
possible but significantly more complex. Evaluate based on target deployment size.

**Q4: Partition naming and `drop_old_partitions()` generalization.**
In Phase 1, `drop_old_partitions()` handles only `statement_snapshots`. In Phase 2,
it must cover all snapshot tier tables. The pattern `tablename like 'X_%'` and
`to_date(right(tablename, 10), 'YYYY_MM_DD')` generalizes cleanly — the function
iterates over all `pgfr_record` tables matching the date suffix pattern. A single
call covers all partitioned tables in the schema.

**Q5: Managed provider compatibility.**
Partitioned tables, `drop table`, and pg_cron are supported on RDS, Cloud SQL,
Supabase, and Neon. The daily partition pre-creation and drop jobs require pg_cron
scheduling rights. No superuser required for partition management after initial
install.
