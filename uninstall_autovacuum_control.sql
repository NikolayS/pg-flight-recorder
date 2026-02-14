-- =============================================================================
-- pg_flight_recorder: Uninstall Autovacuum Control Functions
-- =============================================================================
-- Removes all functions installed by autovacuum_control.sql and restores the
-- vacuum_control_mode stub so _collect_table_stats keeps working.
--
-- Usage: psql --single-transaction -f uninstall_autovacuum_control.sql
-- =============================================================================

-- Drop flight_recorder_reporting schema functions
DROP FUNCTION IF EXISTS flight_recorder_reporting.time_to_oid_exhaustion();
DROP FUNCTION IF EXISTS flight_recorder_reporting.oid_consumption_rate(INTERVAL);
DROP FUNCTION IF EXISTS flight_recorder_reporting.time_to_budget_exhaustion(OID, BIGINT);
DROP FUNCTION IF EXISTS flight_recorder_reporting.bloat_report(INTERVAL);
DROP FUNCTION IF EXISTS flight_recorder_reporting.estimate_table_bloat(OID);
DROP FUNCTION IF EXISTS flight_recorder_reporting.table_size_growth_rate(OID, INTERVAL);
DROP FUNCTION IF EXISTS flight_recorder_reporting.dead_tuple_growth_rate(OID, INTERVAL);

-- Drop flight_recorder schema functions
DROP FUNCTION IF EXISTS flight_recorder.vacuum_control_report(TIMESTAMPTZ, TIMESTAMPTZ);
DROP FUNCTION IF EXISTS flight_recorder.vacuum_diagnostic(OID);
DROP FUNCTION IF EXISTS flight_recorder.compute_recommended_scale_factor(OID);
DROP FUNCTION IF EXISTS flight_recorder.vacuum_control_mode(OID);
DROP FUNCTION IF EXISTS flight_recorder.dead_tuple_trend(OID, INTERVAL);
DROP FUNCTION IF EXISTS flight_recorder._get_table_autovacuum_settings(OID);
DROP FUNCTION IF EXISTS flight_recorder.time_to_budget_exhaustion(OID, BIGINT);
DROP FUNCTION IF EXISTS flight_recorder.dead_tuple_growth_rate(OID, INTERVAL);

-- Restore the vacuum_control_mode stub needed by _collect_table_stats
CREATE OR REPLACE FUNCTION flight_recorder.vacuum_control_mode(
    p_relid OID
)
RETURNS TABLE(
    mode        TEXT,
    reason      TEXT,
    entered_at  TIMESTAMPTZ,
    evidence    TEXT
)
LANGUAGE sql STABLE AS $$
    SELECT
        'normal'::TEXT,
        'Autovacuum control not installed'::TEXT,
        now(),
        NULL::TEXT;
$$;
COMMENT ON FUNCTION flight_recorder.vacuum_control_mode(OID) IS 'Stub: returns normal mode. Install autovacuum_control.sql for full vacuum control.';
