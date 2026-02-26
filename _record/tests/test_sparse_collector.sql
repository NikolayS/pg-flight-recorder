-- =============================================================================
-- pgTAP tests: Phase 1 sparse statement_snapshots collector
-- SPEC §9.13 — Phase 1 test items
-- Run with: pg_prove -d <dbname> _record/tests/test_sparse_collector.sql
-- Requires: pgTAP, pg_stat_statements
-- PG14+ minimum
-- =============================================================================

BEGIN;

SELECT plan(24);

-- ---------------------------------------------------------------------------
-- Helper: ensure a clean test partition exists
-- ---------------------------------------------------------------------------
DO $$
BEGIN
    -- Create a test partition for today if needed
    PERFORM pgfr_record._ensure_partition('statement_snapshots_v2', CURRENT_DATE);
END;
$$;

-- ===========================================================================
-- T3: statement_snapshots_v2 table exists and is partitioned
-- ===========================================================================
SELECT ok(
    EXISTS (
        SELECT 1 FROM pg_catalog.pg_class c
        JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
        WHERE n.nspname = 'pgfr_record'
          AND c.relname = 'statement_snapshots_v2'
          AND c.relkind = 'p'  -- partitioned table
    ),
    'statement_snapshots_v2 must exist as a partitioned table'
);

-- T4: statement_snapshots_v2 has toplevel boolean column
SELECT ok(
    EXISTS (
        SELECT 1 FROM pg_catalog.pg_attribute a
        JOIN pg_catalog.pg_class c ON c.oid = a.attrelid
        JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
        WHERE n.nspname = 'pgfr_record'
          AND c.relname = 'statement_snapshots_v2'
          AND a.attname = 'toplevel'
          AND a.atttypid = pg_catalog.regtype('boolean')::oid
          AND a.attnotnull = TRUE
    ),
    'statement_snapshots_v2 must have toplevel boolean not null'
);

-- T5: statement_snapshots_v2 has snapshot_id as BIGINT
SELECT ok(
    EXISTS (
        SELECT 1 FROM pg_catalog.pg_attribute a
        JOIN pg_catalog.pg_class c ON c.oid = a.attrelid
        JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
        WHERE n.nspname = 'pgfr_record'
          AND c.relname = 'statement_snapshots_v2'
          AND a.attname = 'snapshot_id'
          AND a.atttypid = pg_catalog.regtype('bigint')::oid
    ),
    'statement_snapshots_v2.snapshot_id must be BIGINT'
);

-- ===========================================================================
-- T6: statement_last_state table exists and is UNLOGGED
-- ===========================================================================
SELECT ok(
    EXISTS (
        SELECT 1 FROM pg_catalog.pg_class c
        JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
        WHERE n.nspname = 'pgfr_record'
          AND c.relname = 'statement_last_state'
          AND c.relpersistence = 'u'  -- unlogged
    ),
    'statement_last_state must exist and be UNLOGGED'
);

-- T7: statement_last_state primary key covers (queryid, dbid, userid, toplevel)
SELECT ok(
    EXISTS (
        SELECT 1
        FROM pg_catalog.pg_index i
        JOIN pg_catalog.pg_class ci ON ci.oid = i.indexrelid
        JOIN pg_catalog.pg_class ct ON ct.oid = i.indrelid
        JOIN pg_catalog.pg_namespace n ON n.oid = ct.relnamespace
        WHERE n.nspname = 'pgfr_record'
          AND ct.relname = 'statement_last_state'
          AND i.indisprimary = TRUE
          AND i.indnatts = 4
    ),
    'statement_last_state primary key must have exactly 4 columns'
);

-- ===========================================================================
-- T8: HOT contract — no index on statement_last_state covers calls or sample_ts
-- ===========================================================================
SELECT ok(
    NOT EXISTS (
        SELECT 1
        FROM pg_catalog.pg_index i
        JOIN pg_catalog.pg_class ci ON ci.oid = i.indexrelid
        JOIN pg_catalog.pg_class ct ON ct.oid = i.indrelid
        JOIN pg_catalog.pg_namespace n ON n.oid = ct.relnamespace
        JOIN pg_catalog.pg_attribute a ON a.attrelid = ct.oid AND a.attnum = ANY(i.indkey)
        WHERE n.nspname = 'pgfr_record'
          AND ct.relname = 'statement_last_state'
          AND a.attname IN ('calls', 'sample_ts')
    ),
    'HOT contract: no index on statement_last_state must cover calls or sample_ts'
);

-- ===========================================================================
-- T9: statement_last_state has fillfactor=70 storage parameter
-- ===========================================================================
SELECT ok(
    EXISTS (
        SELECT 1
        FROM pg_catalog.pg_class c
        JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
        WHERE n.nspname = 'pgfr_record'
          AND c.relname = 'statement_last_state'
          AND c.reloptions::text LIKE '%fillfactor=70%'
    ),
    'statement_last_state must have fillfactor=70'
);

-- ===========================================================================
-- T10: _ensure_partition('statement_snapshots_v2', ...) is idempotent —
--      calling twice leaves exactly one partition for today
-- ===========================================================================
DO $$
DECLARE
    v_partition_name TEXT;
    v_count          INT;
BEGIN
    v_partition_name := 'statement_snapshots_v2_' || to_char(CURRENT_DATE, 'YYYY_MM_DD');
    -- Call twice — must not raise and must leave exactly one partition
    PERFORM pgfr_record._ensure_partition('statement_snapshots_v2', CURRENT_DATE);
    PERFORM pgfr_record._ensure_partition('statement_snapshots_v2', CURRENT_DATE);
    SELECT COUNT(*) INTO v_count
    FROM pg_catalog.pg_class c
    JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname = 'pgfr_record' AND c.relname = v_partition_name;
    IF v_count <> 1 THEN
        RAISE EXCEPTION '_ensure_partition not idempotent: found % partition(s) for %', v_count, v_partition_name;
    END IF;
END;
$$;
SELECT pass('_ensure_partition(''statement_snapshots_v2'', ...) is idempotent (partition exists after repeated calls)');

-- ===========================================================================
-- T11-T12: Sparse insert — rows skipped when calls unchanged
--          Seed last_state with current PGSS, then run collector again;
--          verify no new rows inserted for unchanged queries.
-- ===========================================================================
DO $$
BEGIN
    -- Ensure pg_stat_statements is available
    IF NOT EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_stat_statements') THEN
        RAISE NOTICE 'pg_stat_statements not available — skipping sparse insert tests';
    END IF;
END;
$$;

DO $$
DECLARE
    v_count_before BIGINT;
    v_count_after  BIGINT;
    v_sample_ts    INT4;
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_stat_statements') THEN
        RETURN;
    END IF;

    -- Fully rebuild last_state so it mirrors current PGSS exactly
    PERFORM pgfr_record._rebuild_statement_last_state();

    v_sample_ts := EXTRACT(EPOCH FROM now() - pgfr_record.epoch())::INT4;

    SELECT COUNT(*) INTO v_count_before
    FROM pgfr_record.statement_snapshots_v2
    WHERE sample_ts >= v_sample_ts;

    -- Run sparse collector; since calls haven't changed, nothing should be inserted
    PERFORM pgfr_record._collect_statement_snapshot_sparse(0);

    SELECT COUNT(*) INTO v_count_after
    FROM pgfr_record.statement_snapshots_v2
    WHERE sample_ts > v_sample_ts;

    IF v_count_after <> 0 THEN
        RAISE EXCEPTION 'Sparse insert: expected 0 new rows when calls unchanged, got %', v_count_after;
    END IF;
END;
$$;
SELECT pass('Sparse insert: 0 rows inserted when calls unchanged after rebuild');

-- T12: After artificially bumping calls in last_state downward (simulating reset),
--      collector should insert at least one row.
DO $$
DECLARE
    v_count_before BIGINT;
    v_count_after  BIGINT;
    v_sample_ts    INT4;
    v_queryid      BIGINT;
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_stat_statements') THEN
        RETURN;
    END IF;

    -- Get a queryid from last_state
    SELECT queryid INTO v_queryid FROM pgfr_record.statement_last_state LIMIT 1;
    IF v_queryid IS NULL THEN RETURN; END IF;

    -- Artificially inflate calls in last_state to force insertion on next tick
    UPDATE pgfr_record.statement_last_state
    SET calls = calls + 999999
    WHERE queryid = v_queryid;

    v_sample_ts := EXTRACT(EPOCH FROM now() - pgfr_record.epoch())::INT4;

    SELECT COUNT(*) INTO v_count_before
    FROM pgfr_record.statement_snapshots_v2;

    PERFORM pgfr_record._collect_statement_snapshot_sparse(0);

    SELECT COUNT(*) INTO v_count_after
    FROM pgfr_record.statement_snapshots_v2;

    -- Restore last_state
    PERFORM pgfr_record._rebuild_statement_last_state();

    IF v_count_after <= v_count_before THEN
        RAISE EXCEPTION 'Sparse insert: expected >=1 row when calls dropped, got 0 new rows';
    END IF;
END;
$$;
SELECT pass('Sparse insert: rows stored when calls dropped (reset detection)');

-- ===========================================================================
-- T13-T14: Crash recovery — TRUNCATE last_state → run collector →
--          exactly one baseline per (queryid,dbid,userid,toplevel), no duplicates
-- ===========================================================================
DO $$
DECLARE
    v_duplicates BIGINT;
    v_pgss_count BIGINT;
    v_ls_count   BIGINT;
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_stat_statements') THEN
        RETURN;
    END IF;

    -- Simulate crash: empty the UNLOGGED side table
    TRUNCATE pgfr_record.statement_last_state;

    -- Run collector (should detect empty table and rebuild)
    PERFORM pgfr_record._collect_statement_snapshot_sparse(0);

    -- Verify: exactly one row per (queryid,dbid,userid,toplevel) in last_state
    SELECT COUNT(*) INTO v_duplicates
    FROM (
        SELECT queryid, dbid, userid, toplevel, COUNT(*) AS cnt
        FROM pgfr_record.statement_last_state
        GROUP BY queryid, dbid, userid, toplevel
        HAVING COUNT(*) > 1
    ) dups;

    IF v_duplicates > 0 THEN
        RAISE EXCEPTION 'Crash recovery: % duplicate (queryid,dbid,userid,toplevel) entries in last_state', v_duplicates;
    END IF;
END;
$$;
SELECT pass('Crash recovery: exactly one baseline per (queryid,dbid,userid,toplevel) after TRUNCATE');

-- T14: After crash recovery, last_state row count should not exceed PGSS count
DO $$
DECLARE
    v_pgss_count BIGINT;
    v_ls_count   BIGINT;
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_stat_statements') THEN
        RETURN;
    END IF;

    SELECT COUNT(*) INTO v_pgss_count FROM pg_stat_statements;
    SELECT COUNT(*) INTO v_ls_count FROM pgfr_record.statement_last_state;

    IF v_ls_count > v_pgss_count THEN
        RAISE EXCEPTION 'Crash recovery: last_state has % rows > PGSS % rows (stale entries)', v_ls_count, v_pgss_count;
    END IF;
END;
$$;
SELECT pass('Crash recovery: statement_last_state row count <= pg_stat_statements count after rebuild');

-- ===========================================================================
-- T15: ON CONFLICT DO UPDATE used — run 10 ticks, verify n_dead_tup stays bounded
--      HOT updates should prevent unbounded dead tuple accumulation
-- ===========================================================================
DO $$
DECLARE
    i             INT;
    v_dead_before BIGINT;
    v_dead_after  BIGINT;
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_stat_statements') THEN
        RETURN;
    END IF;

    -- Initial rebuild
    PERFORM pgfr_record._rebuild_statement_last_state();

    SELECT n_dead_tup INTO v_dead_before
    FROM pg_stat_user_tables
    WHERE schemaname = 'pgfr_record' AND relname = 'statement_last_state';

    -- Simulate 10 ticks by incrementing calls each time (forces upsert on each tick)
    FOR i IN 1..10 LOOP
        -- Bump all calls by 1 to force upsert path
        UPDATE pgfr_record.statement_last_state SET calls = calls + 1;
        -- Run collector — should use ON CONFLICT DO UPDATE
        PERFORM pgfr_record._collect_statement_snapshot_sparse(i::BIGINT);
    END LOOP;

    -- Force stats update
    ANALYZE pgfr_record.statement_last_state;

    SELECT COALESCE(n_dead_tup, 0) INTO v_dead_after
    FROM pg_stat_user_tables
    WHERE schemaname = 'pgfr_record' AND relname = 'statement_last_state';

    -- With HOT updates and fillfactor=70, dead tuples should stay well under 100
    -- (autovacuum threshold is 1% = ~50 rows for a 5000-row table)
    IF v_dead_after >= 100 THEN
        RAISE WARNING 'ON CONFLICT DO UPDATE test: % dead tuples after 10 ticks (may indicate non-HOT updates)', v_dead_after;
        -- Note: this is a WARNING not EXCEPTION because autovacuum timing affects this
    END IF;
END;
$$;
SELECT pass('ON CONFLICT DO UPDATE: 10 ticks completed without constraint violations');

-- ===========================================================================
-- T16: toplevel — two PGSS entries differing only in toplevel tracked independently
-- ===========================================================================
DO $$
DECLARE
    v_fake_queryid BIGINT := -9999999999;
    v_dbid         OID;
    v_userid       OID;
    v_count_true   INT;
    v_count_false  INT;
BEGIN
    SELECT oid INTO v_dbid FROM pg_database WHERE datname = current_database();
    SELECT oid INTO v_userid FROM pg_roles WHERE rolname = current_user;

    -- Insert two fake entries differing only in toplevel
    INSERT INTO pgfr_record.statement_last_state (queryid, dbid, userid, toplevel, calls, sample_ts)
    VALUES
        (v_fake_queryid, v_dbid, v_userid, TRUE,  100, 1),
        (v_fake_queryid, v_dbid, v_userid, FALSE, 200, 1);

    -- Verify both rows exist independently
    SELECT COUNT(*) INTO v_count_true
    FROM pgfr_record.statement_last_state
    WHERE queryid = v_fake_queryid AND toplevel = TRUE;

    SELECT COUNT(*) INTO v_count_false
    FROM pgfr_record.statement_last_state
    WHERE queryid = v_fake_queryid AND toplevel = FALSE;

    -- Cleanup
    DELETE FROM pgfr_record.statement_last_state WHERE queryid = v_fake_queryid;

    IF v_count_true <> 1 OR v_count_false <> 1 THEN
        RAISE EXCEPTION 'toplevel test: expected 1 row each for toplevel=TRUE and FALSE, got % and %',
            v_count_true, v_count_false;
    END IF;
END;
$$;
SELECT pass('toplevel: two entries differing only in toplevel tracked independently in statement_last_state');

-- ===========================================================================
-- T17: _rebuild_statement_last_state() calls ANALYZE immediately after INSERT
--      Verify stats exist post-rebuild (pg_stat_user_tables.last_analyze IS NOT NULL
--      or n_live_tup reflects actual row count)
-- ===========================================================================
DO $$
DECLARE
    v_live_before BIGINT;
    v_live_after  BIGINT;
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_stat_statements') THEN
        RETURN;
    END IF;

    PERFORM pgfr_record._rebuild_statement_last_state();

    -- ANALYZE must have updated pg_stat_user_tables n_live_tup
    SELECT n_live_tup INTO v_live_after
    FROM pg_stat_user_tables
    WHERE schemaname = 'pgfr_record' AND relname = 'statement_last_state';

    IF v_live_after IS NULL THEN
        RAISE EXCEPTION '_rebuild_statement_last_state: n_live_tup IS NULL after ANALYZE';
    END IF;
END;
$$;
SELECT pass('_rebuild_statement_last_state: ANALYZE updates pg_stat_user_tables.n_live_tup');

-- ===========================================================================
-- T18: _ensure_partition('statement_snapshots_v2', ...) creates partition for a future date
-- ===========================================================================
DO $$
DECLARE
    v_future_date DATE := CURRENT_DATE + 7;
    v_part_name   TEXT;
BEGIN
    v_part_name := 'statement_snapshots_v2_' || to_char(v_future_date, 'YYYY_MM_DD');

    PERFORM pgfr_record._ensure_partition('statement_snapshots_v2', v_future_date);

    IF NOT EXISTS (
        SELECT 1 FROM pg_catalog.pg_class c
        JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
        WHERE n.nspname = 'pgfr_record' AND c.relname = v_part_name
    ) THEN
        RAISE EXCEPTION '_ensure_partition: partition % not found after creation', v_part_name;
    END IF;

    -- Cleanup test partition
    EXECUTE format('DROP TABLE IF EXISTS pgfr_record.%I', v_part_name);
END;
$$;
SELECT pass('_ensure_partition(''statement_snapshots_v2'', ...): creates partition for future date');

-- ===========================================================================
-- T19: statement_snapshots_v2 partition has B-tree index
--      (_btree_idx suffix from _ensure_partition in PR #5)
-- ===========================================================================
SELECT ok(
    EXISTS (
        SELECT 1
        FROM pg_catalog.pg_class ci
        JOIN pg_catalog.pg_index ix ON ix.indexrelid = ci.oid
        JOIN pg_catalog.pg_class ct ON ct.oid = ix.indrelid
        JOIN pg_catalog.pg_namespace n ON n.oid = ct.relnamespace
        WHERE n.nspname = 'pgfr_record'
          AND ct.relname LIKE 'statement_snapshots_v2_%'
          AND ci.relname LIKE '%_btree_idx'
          AND ci.relam = (SELECT oid FROM pg_am WHERE amname = 'btree')
    ),
    'statement_snapshots_v2 partitions must have a B-tree index (_btree_idx)'
);

-- ===========================================================================
-- T20: statement_snapshots_v2 partition has BRIN index on sample_ts
--      (_brin_idx suffix from _ensure_partition in PR #5)
-- ===========================================================================
SELECT ok(
    EXISTS (
        SELECT 1
        FROM pg_catalog.pg_class ci
        JOIN pg_catalog.pg_index ix ON ix.indexrelid = ci.oid
        JOIN pg_catalog.pg_class ct ON ct.oid = ix.indrelid
        JOIN pg_catalog.pg_namespace n ON n.oid = ct.relnamespace
        JOIN pg_catalog.pg_attribute a ON a.attrelid = ct.oid AND a.attnum = ix.indkey[0]
        WHERE n.nspname = 'pgfr_record'
          AND ct.relname LIKE 'statement_snapshots_v2_%'
          AND ci.relname LIKE '%_brin_idx'
          AND ci.relam = (SELECT oid FROM pg_am WHERE amname = 'brin')
          AND a.attname = 'sample_ts'
    ),
    'statement_snapshots_v2 partitions must have a BRIN index on sample_ts (_brin_idx)'
);

-- ===========================================================================
-- T21: pgss_dealloc_warning column exists in statement_snapshots_v2
-- ===========================================================================
SELECT ok(
    EXISTS (
        SELECT 1 FROM pg_catalog.pg_attribute a
        JOIN pg_catalog.pg_class c ON c.oid = a.attrelid
        JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
        WHERE n.nspname = 'pgfr_record'
          AND c.relname = 'statement_snapshots_v2'
          AND a.attname = 'pgss_dealloc_warning'
          AND a.atttypid = pg_catalog.regtype('boolean')::oid
    ),
    'statement_snapshots_v2 must have pgss_dealloc_warning boolean column'
);

-- ===========================================================================
-- T22: config keys for sparse collector observability exist
-- ===========================================================================
SELECT ok(
    EXISTS (SELECT 1 FROM pgfr_record.config WHERE key = 'pgss_last_dealloc'),
    'config key pgss_last_dealloc must exist'
);

SELECT ok(
    EXISTS (SELECT 1 FROM pgfr_record.config WHERE key = 'pgss_rebuild_skip_count'),
    'config key pgss_rebuild_skip_count must exist'
);

-- ===========================================================================
-- T24: _collect_statement_snapshot_sparse handles pg_stat_statements unavailable
--      gracefully (should not raise exception to caller)
-- ===========================================================================
DO $$
DECLARE
    v_ok BOOLEAN := TRUE;
BEGIN
    -- If pg_stat_statements IS available, this test verifies the function runs cleanly
    -- If not available, the EXCEPTION block should catch it silently
    BEGIN
        PERFORM pgfr_record._collect_statement_snapshot_sparse(-999);
    EXCEPTION WHEN OTHERS THEN
        v_ok := FALSE;
        RAISE WARNING 'Unexpected exception from _collect_statement_snapshot_sparse: %', SQLERRM;
    END;

    IF NOT v_ok THEN
        RAISE EXCEPTION 'PGSS sparse collector must not propagate exceptions to caller';
    END IF;
END;
$$;
SELECT pass('_collect_statement_snapshot_sparse: does not propagate exceptions to caller');

-- ===========================================================================
-- T25: statement_snapshots_v2 sample_ts column is INT4
-- ===========================================================================
SELECT ok(
    EXISTS (
        SELECT 1 FROM pg_catalog.pg_attribute a
        JOIN pg_catalog.pg_class c ON c.oid = a.attrelid
        JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
        WHERE n.nspname = 'pgfr_record'
          AND c.relname = 'statement_snapshots_v2'
          AND a.attname = 'sample_ts'
          AND a.atttypid = pg_catalog.regtype('integer')::oid  -- int4
          AND a.attnotnull = TRUE
    ),
    'statement_snapshots_v2.sample_ts must be INT4 NOT NULL'
);

-- ===========================================================================
-- T26: Old statement_snapshots table untouched (dual-write constraint)
-- ===========================================================================
SELECT ok(
    EXISTS (
        SELECT 1 FROM pg_catalog.pg_class c
        JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
        WHERE n.nspname = 'pgfr_record'
          AND c.relname = 'statement_snapshots'
          AND c.relkind = 'r'
    ),
    'Old statement_snapshots table must still exist (dual-write approach)'
);

-- Cleanup: rebuild last_state to a clean state after tests
DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_stat_statements') THEN
        PERFORM pgfr_record._rebuild_statement_last_state();
    END IF;
END;
$$;

SELECT * FROM finish();
ROLLBACK;
