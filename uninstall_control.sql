-- =============================================================================
-- pgfr_record: Uninstall Autovacuum Control Functions
-- =============================================================================
-- Removes all functions installed by _control/install.sql and restores the
-- vacuum_control_mode stub so _collect_table_stats keeps working.
--
-- Usage: psql --single-transaction -f uninstall_control.sql
-- =============================================================================

-- Drop pgfr_analyze schema functions
DROP FUNCTION IF EXISTS pgfr_analyze.time_to_oid_exhaustion();
DROP FUNCTION IF EXISTS pgfr_analyze.oid_consumption_rate(INTERVAL);
DROP FUNCTION IF EXISTS pgfr_analyze.time_to_budget_exhaustion(OID, BIGINT);
DROP FUNCTION IF EXISTS pgfr_analyze.bloat_report(INTERVAL);
DROP FUNCTION IF EXISTS pgfr_analyze.estimate_table_bloat(OID);
DROP FUNCTION IF EXISTS pgfr_analyze.table_size_growth_rate(OID, INTERVAL);
DROP FUNCTION IF EXISTS pgfr_analyze.dead_tuple_growth_rate(OID, INTERVAL);

-- Drop pgfr schema functions
DROP FUNCTION IF EXISTS pgfr.vacuum_control_report(TIMESTAMPTZ, TIMESTAMPTZ);
DROP FUNCTION IF EXISTS pgfr.vacuum_diagnostic(OID);
DROP FUNCTION IF EXISTS pgfr.compute_recommended_scale_factor(OID);
DROP FUNCTION IF EXISTS pgfr.vacuum_control_mode(OID);
DROP FUNCTION IF EXISTS pgfr.dead_tuple_trend(OID, INTERVAL);
DROP FUNCTION IF EXISTS pgfr._get_table_autovacuum_settings(OID);
DROP FUNCTION IF EXISTS pgfr.time_to_budget_exhaustion(OID, BIGINT);
DROP FUNCTION IF EXISTS pgfr.dead_tuple_growth_rate(OID, INTERVAL);

-- Restore the vacuum_control_mode stub needed by _collect_table_stats
CREATE OR REPLACE FUNCTION pgfr.vacuum_control_mode(
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
COMMENT ON FUNCTION pgfr.vacuum_control_mode(OID) IS 'Stub: returns normal mode. Install _control/install.sql for full vacuum control.';
