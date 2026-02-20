-- =============================================================================
-- pgfr_analyze pgTAP Tests - Query Storm Detection
-- =============================================================================
-- Tests: pgfr_analyze.detect_query_storms function and config settings
-- Test count: 10
-- =============================================================================

BEGIN;
SELECT plan(10);

-- =============================================================================
-- 1. CONFIG SETTINGS (6 tests)
-- =============================================================================

SELECT ok(
    EXISTS (SELECT 1 FROM pgfr_record.config WHERE key = 'storm_threshold_multiplier'),
    'storm_threshold_multiplier config setting should exist'
);

SELECT ok(
    EXISTS (SELECT 1 FROM pgfr_record.config WHERE key = 'storm_lookback_interval'),
    'storm_lookback_interval config setting should exist'
);

SELECT ok(
    EXISTS (SELECT 1 FROM pgfr_record.config WHERE key = 'storm_baseline_days'),
    'storm_baseline_days config setting should exist'
);

SELECT ok(
    EXISTS (SELECT 1 FROM pgfr_record.config WHERE key = 'storm_severity_low_max'),
    'storm_severity_low_max config setting should exist'
);

SELECT ok(
    EXISTS (SELECT 1 FROM pgfr_record.config WHERE key = 'storm_severity_medium_max'),
    'storm_severity_medium_max config setting should exist'
);

SELECT ok(
    EXISTS (SELECT 1 FROM pgfr_record.config WHERE key = 'storm_severity_high_max'),
    'storm_severity_high_max config setting should exist'
);

-- =============================================================================
-- 2. FUNCTION EXISTENCE (1 test)
-- =============================================================================

SELECT has_function(
    'pgfr_analyze', 'detect_query_storms', ARRAY['interval', 'numeric'],
    'pgfr_analyze.detect_query_storms(interval, numeric) function should exist'
);

-- =============================================================================
-- 3. FUNCTION EXECUTION (3 tests)
-- =============================================================================

-- Test detect_query_storms executes without error
SELECT lives_ok(
    $$SELECT * FROM pgfr_analyze.detect_query_storms()$$,
    'detect_query_storms() should execute without error'
);

-- Test detect_query_storms with explicit parameters
SELECT lives_ok(
    $$SELECT * FROM pgfr_analyze.detect_query_storms('2 hours'::interval, 5.0)$$,
    'detect_query_storms(interval, numeric) should execute without error'
);

-- Test detect_query_storms returns expected columns
SELECT lives_ok(
    $$SELECT queryid, query_fingerprint, storm_type, severity, recent_count, baseline_count, multiplier
      FROM pgfr_analyze.detect_query_storms()$$,
    'detect_query_storms() should return expected columns'
);

SELECT * FROM finish();
ROLLBACK;
