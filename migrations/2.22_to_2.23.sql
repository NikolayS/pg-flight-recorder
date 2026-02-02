-- =============================================================================
-- Migration: 2.22 to 2.23
-- =============================================================================
-- Description: Add table size tracking for extension-free bloat detection
--
-- Changes:
--   - Add table_size_bytes, total_size_bytes, indexes_size_bytes columns
--     to flight_recorder.table_snapshots
--   - Add table_size_growth_rate() function
--   - Add estimate_table_bloat() function
--   - Add bloat_report() function
--
-- Data preservation: Existing rows will have NULL in new columns (expected -
-- "not collected then" per additive-only schema design)
-- =============================================================================

\set ON_ERROR_STOP on

BEGIN;

-- =============================================================================
-- Step 1: Version Guard
-- =============================================================================
DO $$
DECLARE
    v_current TEXT;
BEGIN
    SELECT value INTO v_current
    FROM flight_recorder.config WHERE key = 'schema_version';

    IF v_current IS NULL THEN
        RAISE EXCEPTION 'schema_version not found. Is Flight Recorder installed?';
    END IF;

    IF v_current != '2.22' THEN
        RAISE EXCEPTION 'Migration 2.22→2.23 requires version 2.22, found %', v_current;
    END IF;

    RAISE NOTICE 'Migrating from 2.22 to 2.23...';
END $$;

-- =============================================================================
-- Step 2: Schema Changes (Data Preserving)
-- =============================================================================

-- Add size tracking columns to table_snapshots
ALTER TABLE flight_recorder.table_snapshots
    ADD COLUMN IF NOT EXISTS table_size_bytes BIGINT,
    ADD COLUMN IF NOT EXISTS total_size_bytes BIGINT,
    ADD COLUMN IF NOT EXISTS indexes_size_bytes BIGINT;

COMMENT ON TABLE flight_recorder.table_snapshots IS
    'Table-level statistics snapshots for hotspot tracking and bloat detection. Includes size metrics for extension-free bloat estimation.';

-- =============================================================================
-- Step 3: Function Updates
-- =============================================================================

-- Calculates the rate of table size growth in bytes per second over a time window
CREATE OR REPLACE FUNCTION flight_recorder.table_size_growth_rate(
    p_relid OID,
    p_window INTERVAL
)
RETURNS NUMERIC
LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_first_snapshot RECORD;
    v_last_snapshot RECORD;
    v_delta_bytes BIGINT;
    v_delta_seconds NUMERIC;
BEGIN
    -- Get earliest snapshot within window
    SELECT ts.table_size_bytes, s.captured_at
    INTO v_first_snapshot
    FROM flight_recorder.table_snapshots ts
    JOIN flight_recorder.snapshots s ON s.id = ts.snapshot_id
    WHERE ts.relid = p_relid
      AND s.captured_at >= now() - p_window
      AND ts.table_size_bytes IS NOT NULL
    ORDER BY s.captured_at ASC
    LIMIT 1;

    -- Get latest snapshot
    SELECT ts.table_size_bytes, s.captured_at
    INTO v_last_snapshot
    FROM flight_recorder.table_snapshots ts
    JOIN flight_recorder.snapshots s ON s.id = ts.snapshot_id
    WHERE ts.relid = p_relid
      AND ts.table_size_bytes IS NOT NULL
    ORDER BY s.captured_at DESC
    LIMIT 1;

    -- Need at least two snapshots to calculate rate
    IF v_first_snapshot IS NULL OR v_last_snapshot IS NULL THEN
        RETURN NULL;
    END IF;

    v_delta_bytes := COALESCE(v_last_snapshot.table_size_bytes, 0) - COALESCE(v_first_snapshot.table_size_bytes, 0);
    v_delta_seconds := EXTRACT(EPOCH FROM (v_last_snapshot.captured_at - v_first_snapshot.captured_at));

    IF v_delta_seconds <= 0 THEN
        RETURN NULL;
    END IF;

    RETURN ROUND(v_delta_bytes::numeric / v_delta_seconds, 4);
END;
$$;
COMMENT ON FUNCTION flight_recorder.table_size_growth_rate(OID, INTERVAL) IS
    'Returns table size growth rate (bytes/second) for a table over a time window. Useful for detecting bloat accumulation.';

-- Estimates table bloat without requiring pgstattuple extension
CREATE OR REPLACE FUNCTION flight_recorder.estimate_table_bloat(
    p_relid OID DEFAULT NULL
)
RETURNS TABLE(
    schemaname          TEXT,
    relname             TEXT,
    relid               OID,
    table_size_bytes    BIGINT,
    total_size_bytes    BIGINT,
    indexes_size_bytes  BIGINT,
    n_live_tup          BIGINT,
    n_dead_tup          BIGINT,
    dead_tuple_pct      NUMERIC,
    est_bytes_per_row   NUMERIC,
    est_live_data_bytes BIGINT,
    est_bloat_bytes     BIGINT,
    est_bloat_pct       NUMERIC,
    bloat_status        TEXT
)
LANGUAGE plpgsql STABLE AS $$
BEGIN
    RETURN QUERY
    WITH latest AS (
        SELECT DISTINCT ON (ts.relid)
            ts.schemaname,
            ts.relname,
            ts.relid,
            ts.table_size_bytes,
            ts.total_size_bytes,
            ts.indexes_size_bytes,
            ts.n_live_tup,
            ts.n_dead_tup
        FROM flight_recorder.table_snapshots ts
        JOIN flight_recorder.snapshots s ON s.id = ts.snapshot_id
        WHERE ts.table_size_bytes IS NOT NULL
          AND (p_relid IS NULL OR ts.relid = p_relid)
        ORDER BY ts.relid, s.captured_at DESC
    ),
    with_estimates AS (
        SELECT
            l.*,
            -- Dead tuple percentage
            CASE
                WHEN COALESCE(l.n_live_tup, 0) + COALESCE(l.n_dead_tup, 0) > 0
                THEN round(100.0 * COALESCE(l.n_dead_tup, 0) /
                     (COALESCE(l.n_live_tup, 0) + COALESCE(l.n_dead_tup, 0)), 1)
                ELSE 0
            END AS dead_pct,
            -- Estimated bytes per row (if we have live tuples and size data)
            CASE
                WHEN COALESCE(l.n_live_tup, 0) > 100 AND COALESCE(l.table_size_bytes, 0) > 0
                THEN round(l.table_size_bytes::numeric / l.n_live_tup, 2)
                ELSE NULL
            END AS bytes_per_row
        FROM latest l
    )
    SELECT
        e.schemaname::TEXT,
        e.relname::TEXT,
        e.relid,
        e.table_size_bytes,
        e.total_size_bytes,
        e.indexes_size_bytes,
        e.n_live_tup,
        e.n_dead_tup,
        e.dead_pct,
        e.bytes_per_row,
        -- Estimated live data bytes (rough: live_tuples * bytes_per_row, adjusted for overhead)
        CASE
            WHEN e.bytes_per_row IS NOT NULL AND e.n_live_tup > 0
            THEN (e.n_live_tup * e.bytes_per_row * 0.85)::BIGINT  -- 15% overhead estimate
            ELSE NULL
        END AS live_data_bytes,
        -- Estimated bloat bytes
        CASE
            WHEN e.bytes_per_row IS NOT NULL AND e.n_live_tup > 0
            THEN greatest(0, e.table_size_bytes - (e.n_live_tup * e.bytes_per_row * 0.85)::BIGINT)
            ELSE NULL
        END AS bloat_bytes,
        -- Estimated bloat percentage
        CASE
            WHEN e.bytes_per_row IS NOT NULL AND e.n_live_tup > 0 AND e.table_size_bytes > 0
            THEN round(100.0 * greatest(0, e.table_size_bytes - (e.n_live_tup * e.bytes_per_row * 0.85)::BIGINT) / e.table_size_bytes, 1)
            ELSE e.dead_pct  -- Fall back to dead tuple percentage as bloat proxy
        END AS bloat_pct,
        -- Status classification
        CASE
            WHEN e.dead_pct >= 50 THEN 'critical'
            WHEN e.dead_pct >= 25 THEN 'high'
            WHEN e.dead_pct >= 10 THEN 'moderate'
            WHEN e.dead_pct >= 5 THEN 'low'
            ELSE 'minimal'
        END::TEXT AS status
    FROM with_estimates e
    ORDER BY e.dead_pct DESC, e.table_size_bytes DESC;
END;
$$;
COMMENT ON FUNCTION flight_recorder.estimate_table_bloat(OID) IS
    'Estimates table bloat without pgstattuple. Uses dead tuple ratio and size metrics. Pass NULL or omit argument for all tables.';

-- Generates a bloat report with trends and recommendations
CREATE OR REPLACE FUNCTION flight_recorder.bloat_report(
    p_window INTERVAL DEFAULT '24 hours'::INTERVAL
)
RETURNS TABLE(
    schemaname          TEXT,
    relname             TEXT,
    current_size        TEXT,
    size_change         TEXT,
    dead_tuple_pct      NUMERIC,
    dead_tuple_trend    TEXT,
    bloat_status        TEXT,
    recommendation      TEXT
)
LANGUAGE plpgsql STABLE AS $$
BEGIN
    RETURN QUERY
    WITH current_stats AS (
        SELECT * FROM flight_recorder.estimate_table_bloat(NULL)
    ),
    historical AS (
        SELECT DISTINCT ON (ts.relid)
            ts.relid,
            ts.table_size_bytes AS old_size,
            ts.n_dead_tup AS old_dead_tup,
            ts.n_live_tup AS old_live_tup
        FROM flight_recorder.table_snapshots ts
        JOIN flight_recorder.snapshots s ON s.id = ts.snapshot_id
        WHERE s.captured_at <= now() - p_window
          AND ts.table_size_bytes IS NOT NULL
        ORDER BY ts.relid, s.captured_at DESC
    )
    SELECT
        c.schemaname,
        c.relname,
        pg_size_pretty(c.table_size_bytes) AS current_size,
        CASE
            WHEN h.old_size IS NULL THEN 'N/A (no history)'
            WHEN c.table_size_bytes > h.old_size
            THEN '+' || pg_size_pretty(c.table_size_bytes - h.old_size)
            WHEN c.table_size_bytes < h.old_size
            THEN '-' || pg_size_pretty(h.old_size - c.table_size_bytes)
            ELSE 'unchanged'
        END AS size_change,
        c.dead_tuple_pct,
        CASE
            WHEN h.old_dead_tup IS NULL THEN 'N/A'
            WHEN COALESCE(c.n_dead_tup, 0) > COALESCE(h.old_dead_tup, 0) * 1.5 THEN 'increasing rapidly'
            WHEN COALESCE(c.n_dead_tup, 0) > COALESCE(h.old_dead_tup, 0) THEN 'increasing'
            WHEN COALESCE(c.n_dead_tup, 0) < COALESCE(h.old_dead_tup, 0) THEN 'decreasing'
            ELSE 'stable'
        END AS dead_tuple_trend,
        c.bloat_status,
        CASE
            WHEN c.bloat_status = 'critical'
            THEN 'URGENT: Run VACUUM FULL or pg_repack immediately'
            WHEN c.bloat_status = 'high'
            THEN 'Run VACUUM FULL or pg_repack soon'
            WHEN c.bloat_status = 'moderate' AND
                 COALESCE(c.n_dead_tup, 0) > COALESCE(h.old_dead_tup, 0) * 1.5
            THEN 'Check autovacuum settings - dead tuples accumulating'
            WHEN c.bloat_status = 'moderate'
            THEN 'Monitor - consider VACUUM if trend continues'
            ELSE 'No action needed'
        END AS recommendation
    FROM current_stats c
    LEFT JOIN historical h ON h.relid = c.relid
    WHERE c.table_size_bytes > 1024 * 1024  -- Only tables > 1MB
    ORDER BY
        CASE c.bloat_status
            WHEN 'critical' THEN 1
            WHEN 'high' THEN 2
            WHEN 'moderate' THEN 3
            WHEN 'low' THEN 4
            ELSE 5
        END,
        c.table_size_bytes DESC;
END;
$$;
COMMENT ON FUNCTION flight_recorder.bloat_report(INTERVAL) IS
    'Generates a bloat report with size trends and recommendations. Compares current state to historical data over the specified window.';

-- =============================================================================
-- Step 4: Update Version
-- =============================================================================
UPDATE flight_recorder.config
SET value = '2.23', updated_at = now()
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
    RAISE NOTICE 'New features:';
    RAISE NOTICE '  - Table size tracking (table_size_bytes, total_size_bytes, indexes_size_bytes)';
    RAISE NOTICE '  - table_size_growth_rate(relid, interval) - bytes/second growth';
    RAISE NOTICE '  - estimate_table_bloat(relid) - extension-free bloat estimation';
    RAISE NOTICE '  - bloat_report(interval) - bloat report with trends';
    RAISE NOTICE '';
    RAISE NOTICE 'Usage:';
    RAISE NOTICE '  SELECT * FROM flight_recorder.bloat_report();';
    RAISE NOTICE '  SELECT * FROM flight_recorder.estimate_table_bloat();';
    RAISE NOTICE '';
END $$;
