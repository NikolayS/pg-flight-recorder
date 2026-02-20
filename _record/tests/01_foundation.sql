-- =============================================================================
-- pgfr_record pgTAP Tests - Foundation
-- =============================================================================
-- Tests: Installation verification, function existence, core functionality
-- Sections: 1, 2, 3
-- Test count: 54
-- =============================================================================

BEGIN;
SELECT plan(54);

-- =============================================================================
-- 1. INSTALLATION VERIFICATION (19 tests)
-- =============================================================================

-- Test schema exists
SELECT has_schema('pgfr', 'Schema pgfr should exist');

-- Test all 14 tables exist (snapshots + ring buffers + aggregates + config + collection_stats)
SELECT has_table('pgfr', 'snapshots', 'Table pgfr.snapshots should exist');
SELECT has_table('pgfr', 'replication_snapshots', 'Table pgfr.replication_snapshots should exist');
SELECT has_table('pgfr', 'statement_snapshots', 'Table pgfr.statement_snapshots should exist');
-- Ring buffers (UNLOGGED)
SELECT has_table('pgfr', 'samples_ring', 'Ring buffer: Table pgfr.samples_ring should exist');
SELECT has_table('pgfr', 'wait_samples_ring', 'Ring buffer: Table pgfr.wait_samples_ring should exist');
SELECT has_table('pgfr', 'activity_samples_ring', 'Ring buffer: Table pgfr.activity_samples_ring should exist');
SELECT has_table('pgfr', 'lock_samples_ring', 'Ring buffer: Table pgfr.lock_samples_ring should exist');
-- Aggregates (REGULAR/durable)
SELECT has_table('pgfr', 'wait_event_aggregates', 'Aggregates: Table pgfr.wait_event_aggregates should exist');
SELECT has_table('pgfr', 'lock_aggregates', 'Aggregates: Table pgfr.lock_aggregates should exist');
SELECT has_table('pgfr', 'activity_aggregates', 'Aggregates: Table pgfr.activity_aggregates should exist');
-- Raw archives (REGULAR/durable)
SELECT has_table('pgfr', 'activity_samples_archive', 'Raw archives: Table pgfr.activity_samples_archive should exist');
SELECT has_table('pgfr', 'lock_samples_archive', 'Raw archives: Table pgfr.lock_samples_archive should exist');
SELECT has_table('pgfr', 'wait_samples_archive', 'Raw archives: Table pgfr.wait_samples_archive should exist');
-- Config and monitoring
SELECT has_table('pgfr', 'config', 'Table pgfr.config should exist');
SELECT has_table('pgfr', 'collection_stats', 'P0 Safety: Table pgfr.collection_stats should exist');

-- Test Foreign Keys (Ring buffer child tables reference master samples_ring)
SELECT ok(
    EXISTS (
        SELECT 1 FROM pg_constraint
        WHERE conrelid = 'pgfr.wait_samples_ring'::regclass
          AND confrelid = 'pgfr.samples_ring'::regclass
          AND contype = 'f'
    ),
    'wait_samples_ring should have FK to samples_ring'
);

SELECT ok(
    EXISTS (
        SELECT 1 FROM pg_constraint
        WHERE conrelid = 'pgfr.activity_samples_ring'::regclass
          AND confrelid = 'pgfr.samples_ring'::regclass
          AND contype = 'f'
    ),
    'activity_samples_ring should have FK to samples_ring'
);

SELECT ok(
    EXISTS (
        SELECT 1 FROM pg_constraint
        WHERE conrelid = 'pgfr.lock_samples_ring'::regclass
          AND confrelid = 'pgfr.samples_ring'::regclass
          AND contype = 'f'
    ),
    'lock_samples_ring should have FK to samples_ring'
);

-- Test all 6 views exist
SELECT has_view('pgfr', 'deltas', 'View pgfr.deltas should exist');
SELECT has_view('pgfr', 'recent_waits', 'View pgfr.recent_waits should exist');

-- =============================================================================
-- 2. FUNCTION EXISTENCE (25 tests)
-- =============================================================================

SELECT has_function('pgfr', '_pg_version', 'Function pgfr._pg_version should exist');
SELECT has_function('pgfr', '_get_config', 'Function pgfr._get_config should exist');
SELECT has_function('pgfr', '_has_pg_stat_statements', 'Function pgfr._has_pg_stat_statements should exist');
SELECT has_function('pgfr', '_pretty_bytes', 'Function pgfr._pretty_bytes should exist');
SELECT has_function('pgfr', '_check_circuit_breaker', 'P0 Safety: Function pgfr._check_circuit_breaker should exist');
SELECT has_function('pgfr', '_record_collection_start', 'P0 Safety: Function pgfr._record_collection_start should exist');
SELECT has_function('pgfr', '_record_collection_end', 'P0 Safety: Function pgfr._record_collection_end should exist');
SELECT has_function('pgfr', '_record_collection_skip', 'P0 Safety: Function pgfr._record_collection_skip should exist');
SELECT has_function('pgfr', '_check_schema_size', 'P1 Safety: Function pgfr._check_schema_size should exist');
SELECT has_function('pgfr', 'snapshot', 'Function pgfr.snapshot should exist');
SELECT has_function('pgfr', 'sample', 'Function pgfr.sample should exist');
SELECT has_function('pgfr', '_compare', 'Function pgfr._compare should exist');
SELECT has_function('pgfr', '_wait_summary', 'Function pgfr._wait_summary should exist');
SELECT has_function('pgfr', '_statement_compare', 'Function pgfr._statement_compare should exist');
SELECT has_function('pgfr', '_activity_at', 'Function pgfr._activity_at should exist');
SELECT has_function('pgfr_analyze', 'anomaly_report', 'Function pgfr_analyze.anomaly_report should exist');
SELECT has_function('pgfr_analyze', 'summary_report', 'Function pgfr_analyze.summary_report should exist');
SELECT has_function('pgfr', 'get_mode', 'Function pgfr.get_mode should exist');
SELECT has_function('pgfr', 'set_mode', 'Function pgfr.set_mode should exist');
SELECT has_function('pgfr', 'cleanup', 'Function pgfr.cleanup should exist');
-- Ring buffer functions
SELECT has_function('pgfr', 'flush_ring_to_aggregates', 'Aggregates: Function pgfr.flush_ring_to_aggregates should exist');
SELECT has_function('pgfr', 'archive_ring_samples', 'Raw archives: Function pgfr.archive_ring_samples should exist');
SELECT has_function('pgfr', 'cleanup_aggregates', 'Cleanup: Function pgfr.cleanup_aggregates should exist');

-- =============================================================================
-- 3. CORE FUNCTIONALITY (10 tests)
-- =============================================================================

-- Test snapshot() function works
SELECT lives_ok(
    $$SELECT pgfr.snapshot()$$,
    'snapshot() function should execute without error'
);

-- Verify snapshot was captured
SELECT ok(
    (SELECT count(*) FROM pgfr.snapshots) >= 1,
    'At least one snapshot should be captured'
);

-- Test sample() function works
SELECT lives_ok(
    $$SELECT pgfr.sample()$$,
    'sample() function should execute without error'
);

-- Verify sample was captured in ring buffer
SELECT ok(
    (SELECT count(*) FROM pgfr.samples_ring WHERE captured_at > '2020-01-01') >= 1,
    'At least one sample should be captured in ring buffer'
);

-- Test wait_samples_ring captured
SELECT ok(
    (SELECT count(*) FROM pgfr.wait_samples_ring) >= 1,
    'Wait samples should be captured'
);

-- Test activity_samples_ring captured
SELECT ok(
    (SELECT count(*) FROM pgfr.activity_samples_ring) >= 0,
    'Activity samples table should be queryable (may be empty)'
);

-- Test version detection works
SELECT ok(
    pgfr._pg_version() >= 15,
    'PostgreSQL version should be 15 or higher'
);

-- Test pg_stat_statements detection
SELECT ok(
    pgfr._has_pg_stat_statements() IS NOT NULL,
    'pg_stat_statements detection should work'
);

-- Test pretty bytes formatting
SELECT is(
    pgfr._pretty_bytes(1024),
    '1.00 KB',
    'Pretty bytes should format correctly'
);

-- Test config retrieval
SELECT is(
    pgfr._get_config('mode', 'normal'),
    'normal',
    'Config retrieval should work with defaults'
);

SELECT * FROM finish();
ROLLBACK;
