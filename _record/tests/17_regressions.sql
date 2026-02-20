-- =============================================================================
-- pgfr_record pgTAP Tests - Internal Performance Regression Detection
-- =============================================================================
-- Tests: Internal pgfr._detect_regressions and pgfr._diagnose_regression_causes
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
    'pgfr', '_detect_regressions', ARRAY['interval', 'numeric'],
    'pgfr._detect_regressions(interval, numeric) function should exist'
);

SELECT has_function(
    'pgfr', '_diagnose_regression_causes', ARRAY['bigint'],
    'pgfr._diagnose_regression_causes(bigint) function should exist'
);

-- =============================================================================
-- 3. FUNCTION EXECUTION (2 tests)
-- =============================================================================

-- Test _detect_regressions executes without error
SELECT lives_ok(
    $$SELECT * FROM pgfr._detect_regressions()$$,
    '_detect_regressions() should execute without error'
);

-- Test _diagnose_regression_causes executes without error
SELECT lives_ok(
    $$SELECT pgfr._diagnose_regression_causes(12345)$$,
    '_diagnose_regression_causes() should execute without error'
);

SELECT * FROM finish();
ROLLBACK;
