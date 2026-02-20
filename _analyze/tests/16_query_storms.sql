-- =============================================================================
-- pgfr_record pgTAP Tests - Query Storm Detection
-- =============================================================================
-- Tests: Query storm detection function and configuration
-- Test count: 8
-- =============================================================================

BEGIN;
SELECT plan(8);

-- =============================================================================
-- 1. CONFIG SETTINGS (6 tests)
-- =============================================================================

SELECT ok(
    EXISTS (SELECT 1 FROM pgfr.config WHERE key = 'storm_threshold_multiplier'),
    'storm_threshold_multiplier config setting should exist'
);

SELECT ok(
    EXISTS (SELECT 1 FROM pgfr.config WHERE key = 'storm_lookback_interval'),
    'storm_lookback_interval config setting should exist'
);

SELECT ok(
    EXISTS (SELECT 1 FROM pgfr.config WHERE key = 'storm_baseline_days'),
    'storm_baseline_days config setting should exist'
);

SELECT ok(
    EXISTS (SELECT 1 FROM pgfr.config WHERE key = 'storm_severity_low_max'),
    'storm_severity_low_max config setting should exist'
);

SELECT ok(
    EXISTS (SELECT 1 FROM pgfr.config WHERE key = 'storm_severity_medium_max'),
    'storm_severity_medium_max config setting should exist'
);

SELECT ok(
    EXISTS (SELECT 1 FROM pgfr.config WHERE key = 'storm_severity_high_max'),
    'storm_severity_high_max config setting should exist'
);

-- =============================================================================
-- 2. FUNCTION EXISTENCE (1 test)
-- =============================================================================

SELECT has_function(
    'pgfr_analyze', 'detect_query_storms', ARRAY['interval', 'numeric'],
    'detect_query_storms(interval, numeric) function should exist'
);

-- =============================================================================
-- 3. FUNCTION EXECUTION (1 test)
-- =============================================================================

-- Test detect_query_storms executes without error
SELECT lives_ok(
    $$SELECT * FROM pgfr_analyze.detect_query_storms()$$,
    'detect_query_storms() should execute without error'
);

SELECT * FROM finish();
ROLLBACK;
