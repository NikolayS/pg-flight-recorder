-- =============================================================================
-- Migration: 2.24 to 2.25
-- =============================================================================
-- Description: Move reporting functions to flight_recorder_reporting schema
--
-- Changes:
--   - Create flight_recorder_reporting schema
--   - Reporting functions/views are now defined in the new schema
--     (users must re-run reporting.sql to pick up the new schema)
--   - Drop old reporting functions from flight_recorder schema
--
-- Data preservation: All data is preserved. Only function locations change.
-- =============================================================================

\set ON_ERROR_STOP on

BEGIN;

-- =============================================================================
-- Step 1: Version Guard
-- =============================================================================
DO $$
DECLARE
    v_current TEXT;
    v_expected TEXT := '2.24';
    v_target TEXT := '2.25';
BEGIN
    SELECT value INTO v_current
    FROM flight_recorder.config WHERE key = 'schema_version';

    IF v_current IS NULL THEN
        RAISE EXCEPTION 'schema_version not found. Is Flight Recorder installed?';
    END IF;

    IF v_current != v_expected THEN
        RAISE EXCEPTION 'Migration 2.24→2.25 requires version %, found %', v_expected, v_current;
    END IF;

    RAISE NOTICE 'Migrating from % to %...', v_expected, v_target;
END $$;

-- =============================================================================
-- Step 2: Create new schema
-- =============================================================================
CREATE SCHEMA IF NOT EXISTS flight_recorder_reporting;

-- =============================================================================
-- Step 3: Drop old reporting functions from flight_recorder schema
-- =============================================================================
-- These will be recreated in flight_recorder_reporting by re-running reporting.sql

DROP VIEW IF EXISTS flight_recorder.capacity_dashboard CASCADE;

DROP FUNCTION IF EXISTS flight_recorder.dead_tuple_growth_rate(OID, INTERVAL) CASCADE;
DROP FUNCTION IF EXISTS flight_recorder.table_size_growth_rate(OID, INTERVAL) CASCADE;
DROP FUNCTION IF EXISTS flight_recorder.estimate_table_bloat(OID) CASCADE;
DROP FUNCTION IF EXISTS flight_recorder.bloat_report(INTERVAL) CASCADE;
DROP FUNCTION IF EXISTS flight_recorder.modification_rate(OID, INTERVAL) CASCADE;
DROP FUNCTION IF EXISTS flight_recorder.hot_update_ratio(OID) CASCADE;
DROP FUNCTION IF EXISTS flight_recorder.time_to_budget_exhaustion(OID, BIGINT) CASCADE;
DROP FUNCTION IF EXISTS flight_recorder.oid_consumption_rate(INTERVAL) CASCADE;
DROP FUNCTION IF EXISTS flight_recorder.time_to_oid_exhaustion() CASCADE;
DROP FUNCTION IF EXISTS flight_recorder.anomaly_report(TIMESTAMPTZ, TIMESTAMPTZ) CASCADE;
DROP FUNCTION IF EXISTS flight_recorder.summary_report(TIMESTAMPTZ, TIMESTAMPTZ) CASCADE;
DROP FUNCTION IF EXISTS flight_recorder.detect_query_storms(INTERVAL, NUMERIC) CASCADE;
DROP FUNCTION IF EXISTS flight_recorder._diagnose_regression_causes(BIGINT) CASCADE;
DROP FUNCTION IF EXISTS flight_recorder.detect_regressions(INTERVAL, NUMERIC) CASCADE;
DROP FUNCTION IF EXISTS flight_recorder.performance_report(INTERVAL) CASCADE;
DROP FUNCTION IF EXISTS flight_recorder.check_alerts(INTERVAL) CASCADE;
DROP FUNCTION IF EXISTS flight_recorder.report(TIMESTAMPTZ, TIMESTAMPTZ) CASCADE;
DROP FUNCTION IF EXISTS flight_recorder.report(INTERVAL) CASCADE;
DROP FUNCTION IF EXISTS flight_recorder.preflight_check() CASCADE;
DROP FUNCTION IF EXISTS flight_recorder.preflight_check_with_summary() CASCADE;
DROP FUNCTION IF EXISTS flight_recorder.quarterly_review() CASCADE;
DROP FUNCTION IF EXISTS flight_recorder.quarterly_review_with_summary() CASCADE;
DROP FUNCTION IF EXISTS flight_recorder.capacity_summary(INTERVAL) CASCADE;
DROP FUNCTION IF EXISTS flight_recorder.capacity_report(INTERVAL) CASCADE;
DROP FUNCTION IF EXISTS flight_recorder.table_compare(TIMESTAMPTZ, TIMESTAMPTZ, INTEGER) CASCADE;
DROP FUNCTION IF EXISTS flight_recorder.table_hotspots(TIMESTAMPTZ, TIMESTAMPTZ) CASCADE;
DROP FUNCTION IF EXISTS flight_recorder.unused_indexes(INTERVAL) CASCADE;
DROP FUNCTION IF EXISTS flight_recorder.index_efficiency(TIMESTAMPTZ, TIMESTAMPTZ, INTEGER) CASCADE;
DROP FUNCTION IF EXISTS flight_recorder.config_changes(TIMESTAMPTZ, TIMESTAMPTZ) CASCADE;
DROP FUNCTION IF EXISTS flight_recorder.config_at(TIMESTAMPTZ, TEXT) CASCADE;
DROP FUNCTION IF EXISTS flight_recorder.config_health_check() CASCADE;
DROP FUNCTION IF EXISTS flight_recorder.db_role_config_at(TIMESTAMPTZ, TEXT, TEXT, TEXT) CASCADE;
DROP FUNCTION IF EXISTS flight_recorder.db_role_config_changes(TIMESTAMPTZ, TIMESTAMPTZ) CASCADE;
DROP FUNCTION IF EXISTS flight_recorder.db_role_config_summary() CASCADE;
DROP FUNCTION IF EXISTS flight_recorder.what_happened_at(TIMESTAMPTZ, INTERVAL) CASCADE;
DROP FUNCTION IF EXISTS flight_recorder.incident_timeline(TIMESTAMPTZ, TIMESTAMPTZ) CASCADE;
DROP FUNCTION IF EXISTS flight_recorder.blast_radius(TIMESTAMPTZ, TIMESTAMPTZ) CASCADE;
DROP FUNCTION IF EXISTS flight_recorder.blast_radius_report(TIMESTAMPTZ, TIMESTAMPTZ) CASCADE;

-- =============================================================================
-- Step 4: Update Version
-- =============================================================================
UPDATE flight_recorder.config
SET value = '2.25', updated_at = now()
WHERE key = 'schema_version';

COMMIT;

-- =============================================================================
-- Step 5: Post-migration verification
-- =============================================================================
DO $$
DECLARE
    v_version TEXT;
BEGIN
    SELECT value INTO v_version
    FROM flight_recorder.config WHERE key = 'schema_version';

    RAISE NOTICE '';
    RAISE NOTICE '=== Migration Complete ===';
    RAISE NOTICE 'Now at version: %', v_version;
    RAISE NOTICE '';
    RAISE NOTICE 'IMPORTANT: Re-run reporting.sql to install reporting functions';
    RAISE NOTICE 'in the new flight_recorder_reporting schema:';
    RAISE NOTICE '  psql -f reporting.sql';
    RAISE NOTICE '';
END $$;
