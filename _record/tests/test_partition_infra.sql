-- =============================================================================
-- pgfr_record pgTAP Tests - Partition Infrastructure (Phase 1)
-- =============================================================================
-- Tests: epoch(), _ensure_partition(), _partition_inventory(),
--        truncate_old_partitions(), drop_ancient_partitions(),
--        partition_gc_health view
-- Test count: 25
-- =============================================================================
--
-- NOTE on test isolation:
--   _partition_inventory() scans ALL pgfr_record partitioned tables.
--   This test creates its own test table (statement_snapshots_v2) to stay
--   hermetic, then drops it at the end.
--
--   Retention window is temporarily lowered to 7 days so that "expired" and
--   "ancient" dates fall within the post-epoch window (epoch = 2026-01-01).
--   We use explicit fixed dates (e.g. 2026-01-15, 2026-01-05) relative to
--   the epoch, not CURRENT_DATE offsets, to avoid pre-epoch date math issues.
--
-- =============================================================================

begin;
select plan(25);

-- =============================================================================
-- SETUP
-- =============================================================================

-- Temporarily lower retention to 7 days so expired/ancient dates are in range.
-- Reverted automatically by ROLLBACK at end of test.
update pgfr_record.config set value = '7' where key = 'retention_snapshots_days';

-- Create a test partitioned parent table mirroring SPEC.md §7.1 structure.
-- Must include (queryid, dbid, userid, toplevel, sample_ts) because
-- _ensure_partition() hardcodes those columns in the B-tree index.
create table pgfr_record.statement_snapshots_v2 (
    sample_ts  int4    not null,
    queryid    bigint  not null,
    dbid       oid     not null,
    userid     oid     not null,
    toplevel   boolean not null default true,
    calls      bigint  not null default 0
) partition by range (sample_ts);

-- =============================================================================
-- T_assert: _partition_inventory() raises exception for non-int4 partition key
-- =============================================================================

do $$
begin
    create table pgfr_record._test_bad_partition_key (
        ts bigint not null
    ) partition by range (ts);
end;
$$;

select throws_ok(
    $$ select * from pgfr_record._partition_inventory() $$,
    'P0001',
    null,
    'T_assert: _partition_inventory() should raise exception for bigint partition key (not int4)'
);

do $$ begin drop table pgfr_record._test_bad_partition_key; end; $$;

-- =============================================================================
-- 1. epoch()
-- =============================================================================

-- T1: epoch() is IMMUTABLE (provolatile = 'i')
select ok(
    (
        select provolatile = 'i'
        from pg_catalog.pg_proc p
        join pg_catalog.pg_namespace n on n.oid = p.pronamespace
        where n.nspname = 'pgfr_record'
          and p.proname = 'epoch'
          and p.pronargs = 0
    ),
    'T1: epoch() should be IMMUTABLE (provolatile = i)'
);

-- T2: epoch() returns exactly '2026-01-01 00:00:00+00'::timestamptz
select is(
    pgfr_record.epoch(),
    '2026-01-01 00:00:00+00'::timestamptz,
    'T2: epoch() should return 2026-01-01 00:00:00+00'
);


-- =============================================================================
-- 2. _ensure_partition()
-- =============================================================================

-- T3: Creates partition for statement_snapshots_v2 for 2026-02-15 without error
select lives_ok(
    $$ select pgfr_record._ensure_partition('statement_snapshots_v2', '2026-02-15'::date) $$,
    'T3: _ensure_partition() should create partition for statement_snapshots_v2 on 2026-02-15 without error'
);

-- T4: Idempotent — calling twice does not error
select lives_ok(
    $$ select pgfr_record._ensure_partition('statement_snapshots_v2', '2026-02-15'::date) $$,
    'T4: _ensure_partition() is idempotent — second call should not error'
);

-- T5: Created partition name follows YYYY_MM_DD convention
select ok(
    exists (
        select 1
        from pg_catalog.pg_class c
        join pg_catalog.pg_namespace n on n.oid = c.relnamespace
        where n.nspname = 'pgfr_record'
          and c.relname = 'statement_snapshots_v2_2026_02_15'
    ),
    'T5: Created partition should be named statement_snapshots_v2_2026_02_15'
);

-- T6: B-tree index exists on (queryid, dbid, userid, toplevel, sample_ts DESC)
select ok(
    exists (
        select 1
        from pg_catalog.pg_index ix
        join pg_catalog.pg_class ic on ic.oid = ix.indexrelid
        join pg_catalog.pg_class tc on tc.oid = ix.indrelid
        join pg_catalog.pg_namespace n on n.oid = tc.relnamespace
        where n.nspname = 'pgfr_record'
          and tc.relname = 'statement_snapshots_v2_2026_02_15'
          and ic.relname = 'statement_snapshots_v2_2026_02_15_btree_idx'
    ),
    'T6: B-tree index statement_snapshots_v2_2026_02_15_btree_idx should exist'
);

-- T7: BRIN index exists on (sample_ts)
select ok(
    exists (
        select 1
        from pg_catalog.pg_index ix
        join pg_catalog.pg_class ic on ic.oid = ix.indexrelid
        join pg_catalog.pg_class tc on tc.oid = ix.indrelid
        join pg_catalog.pg_namespace n on n.oid = tc.relnamespace
        where n.nspname = 'pgfr_record'
          and tc.relname = 'statement_snapshots_v2_2026_02_15'
          and ic.relname = 'statement_snapshots_v2_2026_02_15_brin_idx'
          and ic.relam = (select oid from pg_catalog.pg_am where amname = 'brin')
    ),
    'T7: BRIN index statement_snapshots_v2_2026_02_15_brin_idx should exist with brin access method'
);

-- T7b: BRIN index has pages_per_range = 8
select ok(
    exists (
        select 1
        from pg_catalog.pg_class ic
        join pg_catalog.pg_namespace n on n.oid = ic.relnamespace
        join pg_catalog.pg_options_to_table(ic.reloptions) o(option_name, option_value)
          on o.option_name = 'pages_per_range' and o.option_value = '8'
        where n.nspname = 'pgfr_record'
          and ic.relname = 'statement_snapshots_v2_2026_02_15_brin_idx'
    ),
    'T7b: BRIN index should have pages_per_range = 8'
);

-- T8: UTC bounds correct — bound_start = seconds from epoch() to midnight UTC of 2026-02-15
select is(
    (
        select bound_start
        from pgfr_record._partition_inventory()
        where partition_name = 'statement_snapshots_v2_2026_02_15'
    ),
    extract(epoch from ('2026-02-15 00:00:00+00'::timestamptz - pgfr_record.epoch()))::int4,
    'T8: bound_start should equal seconds from epoch() to midnight UTC of 2026-02-15'
);


-- =============================================================================
-- 3. _partition_inventory()
-- =============================================================================

-- T9: Returns rows for statement_snapshots_v2
select ok(
    exists (
        select 1 from pgfr_record._partition_inventory()
        where parent_table = 'statement_snapshots_v2'
    ),
    'T9: _partition_inventory() should return rows for statement_snapshots_v2'
);

-- T10: is_empty = true for a freshly created empty partition
select ok(
    (
        select is_empty
        from pgfr_record._partition_inventory()
        where partition_name = 'statement_snapshots_v2_2026_02_15'
    ),
    'T10: Freshly created partition should have is_empty = true (pg_relation_size = 0)'
);

-- T11: Today's partition should not be expired (retention=7 days, today's upper bound is tomorrow)
select pgfr_record._ensure_partition('statement_snapshots_v2', current_date);

select ok(
    not (
        select is_expired
        from pgfr_record._partition_inventory()
        where partition_name = 'statement_snapshots_v2_' || to_char(current_date, 'YYYY_MM_DD')
    ),
    'T11: Today''s partition should have is_expired = false'
);

-- T12: is_expired = true for an old partition.
-- With retention=7, the cutoff = today - 7 days.
-- Create a partition for 2026-01-10: upper bound = 2026-01-11, well within expiry range.
select pgfr_record._ensure_partition('statement_snapshots_v2', '2026-01-10'::date);

select ok(
    (
        select is_expired
        from pgfr_record._partition_inventory()
        where partition_name = 'statement_snapshots_v2_2026_01_10'
    ),
    'T12: Partition for 2026-01-10 should have is_expired = true with retention=7 days'
);

-- T13: bound_end for 2026-02-15 partition = seconds from epoch() to midnight UTC 2026-02-16
select is(
    (
        select bound_end
        from pgfr_record._partition_inventory()
        where partition_name = 'statement_snapshots_v2_2026_02_15'
    ),
    extract(epoch from ('2026-02-16 00:00:00+00'::timestamptz - pgfr_record.epoch()))::int4,
    'T13: bound_end should equal seconds from epoch() to midnight UTC of 2026-02-16'
);


-- =============================================================================
-- 4. truncate_old_partitions()
-- =============================================================================

-- T14: Does not error when no expired non-empty partitions exist
-- (2026-01-10 partition was created but is still empty at this point)
select lives_ok(
    $$ select pgfr_record.truncate_old_partitions() $$,
    'T14: truncate_old_partitions() should not error when no expired non-empty partitions exist'
);

-- T15: After inserting data into an expired partition, truncate_old_partitions() empties it.
-- Insert a row into the 2026-01-10 partition (sample_ts within that day's range).
insert into pgfr_record.statement_snapshots_v2 (sample_ts, queryid, dbid, userid, toplevel, calls)
values (
    extract(epoch from ('2026-01-10 12:00:00+00'::timestamptz - pgfr_record.epoch()))::int4,
    12345, 16384, 10, true, 1
);

-- Pre-check: partition should no longer be empty
select ok(
    not (
        select is_empty
        from pgfr_record._partition_inventory()
        where partition_name = 'statement_snapshots_v2_2026_01_10'
    ),
    'T15 pre-check: Expired partition for 2026-01-10 should have data before truncation'
);

select lives_ok(
    $$ select pgfr_record.truncate_old_partitions() $$,
    'T15: truncate_old_partitions() should run without error on an expired non-empty partition'
);

select ok(
    (
        select is_empty
        from pgfr_record._partition_inventory()
        where partition_name = 'statement_snapshots_v2_2026_01_10'
    ),
    'T15: After truncate_old_partitions(), expired partition should be is_empty = true'
);


-- =============================================================================
-- 5. drop_ancient_partitions()
-- =============================================================================

-- T16: Does not error when no ancient empty partitions exist.
-- With retention=7, ancient cutoff = today - 14 days ≈ 2026-02-12.
-- Create a partition for 2026-01-05 (ancient: upper bound 2026-01-06, < 2026-02-12),
-- and leave it empty so drop_ancient_partitions() will target it.
select pgfr_record._ensure_partition('statement_snapshots_v2', '2026-01-05'::date);

select lives_ok(
    $$ select pgfr_record.drop_ancient_partitions() $$,
    'T16: drop_ancient_partitions() should not error and should drop empty ancient partitions'
);

select ok(
    not exists (
        select 1 from pg_catalog.pg_class c
        join pg_catalog.pg_namespace n on n.oid = c.relnamespace
        where n.nspname = 'pgfr_record'
          and c.relname = 'statement_snapshots_v2_2026_01_05'
    ),
    'T16b: ancient empty partition should be physically dropped'
);

-- T17: Does not drop a NON-EMPTY ancient partition.
-- Create another ancient partition (2026-01-03) and insert data into it.
select pgfr_record._ensure_partition('statement_snapshots_v2', '2026-01-03'::date);

insert into pgfr_record.statement_snapshots_v2 (sample_ts, queryid, dbid, userid, toplevel, calls)
values (
    extract(epoch from ('2026-01-03 08:00:00+00'::timestamptz - pgfr_record.epoch()))::int4,
    99999, 16384, 10, true, 5
);

select lives_ok(
    $$ select pgfr_record.drop_ancient_partitions() $$,
    'T17: drop_ancient_partitions() should not error with non-empty ancient partition present'
);

select ok(
    exists (
        select 1
        from pg_catalog.pg_class c
        join pg_catalog.pg_namespace n on n.oid = c.relnamespace
        where n.nspname = 'pgfr_record'
          and c.relname = 'statement_snapshots_v2_2026_01_03'
    ),
    'T17: Non-empty ancient partition should NOT be dropped by drop_ancient_partitions()'
);


-- =============================================================================
-- 6. partition_gc_health view
-- =============================================================================

-- T18: View exists and is queryable
select lives_ok(
    $$ select * from pgfr_record.partition_gc_health $$,
    'T18: partition_gc_health view should be queryable without error'
);

-- T19: pending_truncation = 0 when all data is current.
-- Truncate the 2026-01-03 partition manually, then verify pending_truncation = 0.
truncate pgfr_record.statement_snapshots_v2_2026_01_03;

select ok(
    coalesce(
        (
            select pending_truncation
            from pgfr_record.partition_gc_health
            where parent_table = 'statement_snapshots_v2'
        ),
        0
    ) = 0,
    'T19: pending_truncation should be 0 when no expired partitions hold data'
);


-- =============================================================================
-- TEARDOWN
-- =============================================================================
drop table pgfr_record.statement_snapshots_v2 cascade;

select * from finish();
rollback;
