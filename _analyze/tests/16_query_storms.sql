-- =============================================================================
-- pgfr_analyze pgTAP Tests - Query Storm Detection Wrapper
-- =============================================================================
-- Tests: pgfr_analyze.detect_query_storms wrapper function
-- Test count: 3
-- =============================================================================

BEGIN;
SELECT plan(3);

-- =============================================================================
-- 1. FUNCTION EXISTENCE (1 test)
-- =============================================================================

SELECT has_function(
    'pgfr_analyze', 'detect_query_storms', ARRAY['interval', 'numeric'],
    'pgfr_analyze.detect_query_storms(interval, numeric) wrapper should exist'
);

-- =============================================================================
-- 2. FUNCTION EXECUTION (2 tests)
-- =============================================================================

-- Test detect_query_storms wrapper executes without error
SELECT lives_ok(
    $$SELECT * FROM pgfr_analyze.detect_query_storms()$$,
    'pgfr_analyze.detect_query_storms() should execute without error'
);

-- Test detect_query_storms wrapper with explicit parameters
SELECT lives_ok(
    $$SELECT * FROM pgfr_analyze.detect_query_storms('2 hours'::interval, 5.0)$$,
    'pgfr_analyze.detect_query_storms(interval, numeric) should execute without error'
);

SELECT * FROM finish();
ROLLBACK;
