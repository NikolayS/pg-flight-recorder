-- =============================================================================
-- pgfr_analyze pgTAP Tests - Performance Regression Detection Wrapper
-- =============================================================================
-- Tests: pgfr_analyze.detect_regressions and _diagnose_regression_causes wrappers
-- Test count: 5
-- =============================================================================

BEGIN;
SELECT plan(5);

-- =============================================================================
-- 1. FUNCTION EXISTENCE (2 tests)
-- =============================================================================

SELECT has_function(
    'pgfr_analyze', 'detect_regressions', ARRAY['interval', 'numeric'],
    'pgfr_analyze.detect_regressions(interval, numeric) wrapper should exist'
);

SELECT has_function(
    'pgfr_analyze', '_diagnose_regression_causes', ARRAY['bigint'],
    'pgfr_analyze._diagnose_regression_causes(bigint) wrapper should exist'
);

-- =============================================================================
-- 2. FUNCTION EXECUTION (3 tests)
-- =============================================================================

-- Test detect_regressions wrapper executes without error
SELECT lives_ok(
    $$SELECT * FROM pgfr_analyze.detect_regressions()$$,
    'pgfr_analyze.detect_regressions() should execute without error'
);

-- Test detect_regressions wrapper with explicit parameters
SELECT lives_ok(
    $$SELECT * FROM pgfr_analyze.detect_regressions('2 hours'::interval, 75.0)$$,
    'pgfr_analyze.detect_regressions(interval, numeric) should execute without error'
);

-- Test _diagnose_regression_causes wrapper executes without error
SELECT lives_ok(
    $$SELECT pgfr_analyze._diagnose_regression_causes(12345)$$,
    'pgfr_analyze._diagnose_regression_causes() should execute without error'
);

SELECT * FROM finish();
ROLLBACK;
