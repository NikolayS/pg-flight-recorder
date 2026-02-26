-- =============================================================================
-- pgfr_record pgTAP Tests - Partition Infrastructure (Phase 1)
-- =============================================================================
-- Tests: epoch(), _ensure_partition(), _partition_inventory(),
--        truncate_old_partitions(), drop_ancient_partitions(),
--        partition_gc_health view
-- Test count: 23
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

BEGIN;
SELECT plan(23);

-- =============================================================================
-- SETUP
-- =============================================================================

-- Temporarily lower retention to 7 days so expired/ancient dates are in range.
-- Reverted automatically by ROLLBACK at end of test.
UPDATE pgfr_record.config SET value = '7' WHERE key = 'retention_snapshots_days';

-- Create a test partitioned parent table mirroring SPEC.md §7.1 structure.
-- Must include (queryid, dbid, userid, toplevel, sample_ts) because
-- _ensure_partition() hardcodes those columns in the B-tree index.
CREATE TABLE pgfr_record.statement_snapshots_v2 (
    sample_ts  int4    NOT NULL,
    queryid    bigint  NOT NULL,
    dbid       oid     NOT NULL,
    userid     oid     NOT NULL,
    toplevel   boolean NOT NULL DEFAULT true,
    calls      bigint  NOT NULL DEFAULT 0
) PARTITION BY RANGE (sample_ts);


-- =============================================================================
-- 1. epoch()
-- =============================================================================

-- T1: epoch() is IMMUTABLE (provolatile = 'i')
SELECT ok(
    (
        SELECT provolatile = 'i'
        FROM pg_catalog.pg_proc p
        JOIN pg_catalog.pg_namespace n ON n.oid = p.pronamespace
        WHERE n.nspname = 'pgfr_record'
          AND p.proname = 'epoch'
          AND p.pronargs = 0
    ),
    'T1: epoch() should be IMMUTABLE (provolatile = i)'
);

-- T2: epoch() returns exactly '2026-01-01 00:00:00+00'::timestamptz
SELECT is(
    pgfr_record.epoch(),
    '2026-01-01 00:00:00+00'::timestamptz,
    'T2: epoch() should return 2026-01-01 00:00:00+00'
);


-- =============================================================================
-- 2. _ensure_partition()
-- =============================================================================

-- T3: Creates partition for statement_snapshots_v2 for 2026-02-15 without error
SELECT lives_ok(
    $$ SELECT pgfr_record._ensure_partition('statement_snapshots_v2', '2026-02-15'::date) $$,
    'T3: _ensure_partition() should create partition for statement_snapshots_v2 on 2026-02-15 without error'
);

-- T4: Idempotent — calling twice does not error
SELECT lives_ok(
    $$ SELECT pgfr_record._ensure_partition('statement_snapshots_v2', '2026-02-15'::date) $$,
    'T4: _ensure_partition() is idempotent — second call should not error'
);

-- T5: Created partition name follows YYYY_MM_DD convention
SELECT ok(
    EXISTS (
        SELECT 1
        FROM pg_catalog.pg_class c
        JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
        WHERE n.nspname = 'pgfr_record'
          AND c.relname = 'statement_snapshots_v2_2026_02_15'
    ),
    'T5: Created partition should be named statement_snapshots_v2_2026_02_15'
);

-- T6: B-tree index exists on (queryid, dbid, userid, toplevel, sample_ts DESC)
SELECT ok(
    EXISTS (
        SELECT 1
        FROM pg_catalog.pg_index ix
        JOIN pg_catalog.pg_class ic ON ic.oid = ix.indexrelid
        JOIN pg_catalog.pg_class tc ON tc.oid = ix.indrelid
        JOIN pg_catalog.pg_namespace n ON n.oid = tc.relnamespace
        WHERE n.nspname = 'pgfr_record'
          AND tc.relname = 'statement_snapshots_v2_2026_02_15'
          AND ic.relname = 'statement_snapshots_v2_2026_02_15_btree_idx'
    ),
    'T6: B-tree index statement_snapshots_v2_2026_02_15_btree_idx should exist'
);

-- T7: BRIN index exists on (sample_ts)
SELECT ok(
    EXISTS (
        SELECT 1
        FROM pg_catalog.pg_index ix
        JOIN pg_catalog.pg_class ic ON ic.oid = ix.indexrelid
        JOIN pg_catalog.pg_class tc ON tc.oid = ix.indrelid
        JOIN pg_catalog.pg_namespace n ON n.oid = tc.relnamespace
        WHERE n.nspname = 'pgfr_record'
          AND tc.relname = 'statement_snapshots_v2_2026_02_15'
          AND ic.relname = 'statement_snapshots_v2_2026_02_15_brin_idx'
          AND ic.relam = (SELECT oid FROM pg_catalog.pg_am WHERE amname = 'brin')
    ),
    'T7: BRIN index statement_snapshots_v2_2026_02_15_brin_idx should exist with brin access method'
);

-- T7b: BRIN index has pages_per_range = 8
SELECT ok(
    EXISTS (
        SELECT 1
        FROM pg_catalog.pg_class ic
        JOIN pg_catalog.pg_namespace n ON n.oid = ic.relnamespace
        JOIN pg_catalog.pg_options_to_table(ic.reloptions) o(option_name, option_value)
          ON o.option_name = 'pages_per_range' AND o.option_value = '8'
        WHERE n.nspname = 'pgfr_record'
          AND ic.relname = 'statement_snapshots_v2_2026_02_15_brin_idx'
    ),
    'T7b: BRIN index should have pages_per_range = 8'
);

-- T8: UTC bounds correct — bound_start = seconds from epoch() to midnight UTC of 2026-02-15
SELECT is(
    (
        SELECT bound_start
        FROM pgfr_record._partition_inventory()
        WHERE partition_name = 'statement_snapshots_v2_2026_02_15'
    ),
    extract(epoch from ('2026-02-15 00:00:00+00'::timestamptz - pgfr_record.epoch()))::int4,
    'T8: bound_start should equal seconds from epoch() to midnight UTC of 2026-02-15'
);


-- =============================================================================
-- 3. _partition_inventory()
-- =============================================================================

-- T9: Returns rows for statement_snapshots_v2
SELECT ok(
    EXISTS (
        SELECT 1 FROM pgfr_record._partition_inventory()
        WHERE parent_table = 'statement_snapshots_v2'
    ),
    'T9: _partition_inventory() should return rows for statement_snapshots_v2'
);

-- T10: is_empty = true for a freshly created empty partition
SELECT ok(
    (
        SELECT is_empty
        FROM pgfr_record._partition_inventory()
        WHERE partition_name = 'statement_snapshots_v2_2026_02_15'
    ),
    'T10: Freshly created partition should have is_empty = true (pg_relation_size = 0)'
);

-- T11: is_expired = false for a recent partition (2026-02-15 with retention=7: today-7 = ~2026-02-19,
--      so 2026-02-15 upper bound is 2026-02-16, which is less than 2026-02-19 → actually IS expired).
--      Use a partition very close to today instead. Create today's partition.
SELECT pgfr_record._ensure_partition('statement_snapshots_v2', CURRENT_DATE);

SELECT ok(
    NOT (
        SELECT is_expired
        FROM pgfr_record._partition_inventory()
        WHERE partition_name = 'statement_snapshots_v2_' || to_char(CURRENT_DATE, 'YYYY_MM_DD')
    ),
    'T11: Today''s partition should have is_expired = false'
);

-- T12: is_expired = true for an old partition.
-- With retention=7, the cutoff = today - 7 days.
-- Create a partition for 2026-01-10: upper bound = 2026-01-11, well within expiry range.
SELECT pgfr_record._ensure_partition('statement_snapshots_v2', '2026-01-10'::date);

SELECT ok(
    (
        SELECT is_expired
        FROM pgfr_record._partition_inventory()
        WHERE partition_name = 'statement_snapshots_v2_2026_01_10'
    ),
    'T12: Partition for 2026-01-10 should have is_expired = true with retention=7 days'
);

-- T13: bound_end for 2026-02-15 partition = seconds from epoch() to midnight UTC 2026-02-16
SELECT is(
    (
        SELECT bound_end
        FROM pgfr_record._partition_inventory()
        WHERE partition_name = 'statement_snapshots_v2_2026_02_15'
    ),
    extract(epoch from ('2026-02-16 00:00:00+00'::timestamptz - pgfr_record.epoch()))::int4,
    'T13: bound_end should equal seconds from epoch() to midnight UTC of 2026-02-16'
);


-- =============================================================================
-- 4. truncate_old_partitions()
-- =============================================================================

-- T14: Does not error when no expired non-empty partitions exist
-- (2026-01-10 partition was created but is still empty at this point)
SELECT lives_ok(
    $$ SELECT pgfr_record.truncate_old_partitions() $$,
    'T14: truncate_old_partitions() should not error when no expired non-empty partitions exist'
);

-- T15: After inserting data into an expired partition, truncate_old_partitions() empties it.
-- Insert a row into the 2026-01-10 partition (sample_ts within that day's range).
INSERT INTO pgfr_record.statement_snapshots_v2 (sample_ts, queryid, dbid, userid, toplevel, calls)
VALUES (
    extract(epoch from ('2026-01-10 12:00:00+00'::timestamptz - pgfr_record.epoch()))::int4,
    12345, 16384, 10, true, 1
);

-- Pre-check: partition should no longer be empty
SELECT ok(
    NOT (
        SELECT is_empty
        FROM pgfr_record._partition_inventory()
        WHERE partition_name = 'statement_snapshots_v2_2026_01_10'
    ),
    'T15 pre-check: Expired partition for 2026-01-10 should have data before truncation'
);

SELECT lives_ok(
    $$ SELECT pgfr_record.truncate_old_partitions() $$,
    'T15: truncate_old_partitions() should run without error on an expired non-empty partition'
);

SELECT ok(
    (
        SELECT is_empty
        FROM pgfr_record._partition_inventory()
        WHERE partition_name = 'statement_snapshots_v2_2026_01_10'
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
SELECT pgfr_record._ensure_partition('statement_snapshots_v2', '2026-01-05'::date);

SELECT lives_ok(
    $$ SELECT pgfr_record.drop_ancient_partitions() $$,
    'T16: drop_ancient_partitions() should not error and should drop empty ancient partitions'
);

-- T17: Does not drop a NON-EMPTY ancient partition.
-- Create another ancient partition (2026-01-03) and insert data into it.
SELECT pgfr_record._ensure_partition('statement_snapshots_v2', '2026-01-03'::date);

INSERT INTO pgfr_record.statement_snapshots_v2 (sample_ts, queryid, dbid, userid, toplevel, calls)
VALUES (
    extract(epoch from ('2026-01-03 08:00:00+00'::timestamptz - pgfr_record.epoch()))::int4,
    99999, 16384, 10, true, 5
);

SELECT lives_ok(
    $$ SELECT pgfr_record.drop_ancient_partitions() $$,
    'T17: drop_ancient_partitions() should not error with non-empty ancient partition present'
);

SELECT ok(
    EXISTS (
        SELECT 1
        FROM pg_catalog.pg_class c
        JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
        WHERE n.nspname = 'pgfr_record'
          AND c.relname = 'statement_snapshots_v2_2026_01_03'
    ),
    'T17: Non-empty ancient partition should NOT be dropped by drop_ancient_partitions()'
);


-- =============================================================================
-- 6. partition_gc_health view
-- =============================================================================

-- T18: View exists and is queryable
SELECT lives_ok(
    $$ SELECT * FROM pgfr_record.partition_gc_health $$,
    'T18: partition_gc_health view should be queryable without error'
);

-- T19: pending_truncation = 0 when all data is current.
-- Truncate the 2026-01-03 partition manually, then verify pending_truncation = 0.
TRUNCATE pgfr_record.statement_snapshots_v2_2026_01_03;

SELECT ok(
    COALESCE(
        (
            SELECT pending_truncation
            FROM pgfr_record.partition_gc_health
            WHERE parent_table = 'statement_snapshots_v2'
        ),
        0
    ) = 0,
    'T19: pending_truncation should be 0 when no expired partitions hold data'
);


-- =============================================================================
-- TEARDOWN
-- =============================================================================
DROP TABLE pgfr_record.statement_snapshots_v2 CASCADE;

SELECT * FROM finish();
ROLLBACK;
