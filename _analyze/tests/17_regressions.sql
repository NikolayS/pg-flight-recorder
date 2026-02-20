-- =============================================================================
-- pgfr_record pgTAP Tests - Performance Regression Detection
-- =============================================================================
-- Tests: Performance regression detection function and configuration
-- Test count: 11
-- =============================================================================

BEGIN;
SELECT plan(11);

-- =============================================================================
-- 1. CONFIG SETTINGS (7 tests)
-- =============================================================================

SELECT ok(
    EXISTS (SELECT 1 FROM pgfr.config WHERE key = 'regression_threshold_pct'),
    'regression_threshold_pct config setting should exist'
);

SELECT ok(
    EXISTS (SELECT 1 FROM pgfr.config WHERE key = 'regression_lookback_interval'),
    'regression_lookback_interval config setting should exist'
);

SELECT ok(
    EXISTS (SELECT 1 FROM pgfr.config WHERE key = 'regression_baseline_days'),
    'regression_baseline_days config setting should exist'
);

SELECT ok(
    EXISTS (SELECT 1 FROM pgfr.config WHERE key = 'regression_severity_low_max'),
    'regression_severity_low_max config setting should exist'
);

SELECT ok(
    EXISTS (SELECT 1 FROM pgfr.config WHERE key = 'regression_severity_medium_max'),
    'regression_severity_medium_max config setting should exist'
);

SELECT ok(
    EXISTS (SELECT 1 FROM pgfr.config WHERE key = 'regression_severity_high_max'),
    'regression_severity_high_max config setting should exist'
);

SELECT ok(
    EXISTS (SELECT 1 FROM pgfr.config WHERE key = 'regression_detection_metric'),
    'regression_detection_metric config setting should exist'
);

-- =============================================================================
-- 2. FUNCTION EXISTENCE (2 tests)
-- =============================================================================

SELECT has_function(
    'pgfr_analyze', 'detect_regressions', ARRAY['interval', 'numeric'],
    'detect_regressions(interval, numeric) function should exist'
);

SELECT has_function(
    'pgfr_analyze', '_diagnose_regression_causes', ARRAY['bigint'],
    '_diagnose_regression_causes(bigint) function should exist'
);

-- =============================================================================
-- 3. FUNCTION EXECUTION (2 tests)
-- =============================================================================

-- Test detect_regressions executes without error
SELECT lives_ok(
    $$SELECT * FROM pgfr_analyze.detect_regressions()$$,
    'detect_regressions() should execute without error'
);

-- Test _diagnose_regression_causes executes without error
SELECT lives_ok(
    $$SELECT pgfr_analyze._diagnose_regression_causes(12345)$$,
    '_diagnose_regression_causes() should execute without error'
);

SELECT * FROM finish();
ROLLBACK;
