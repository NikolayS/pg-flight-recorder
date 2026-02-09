-- =============================================================================
-- pg_flight_recorder: Autovacuum Control Functions
-- =============================================================================
-- Optional add-on for install.sql. Provides semiautonomous vacuum settings
-- configuration, dead tuple trend analysis, bloat estimation, and OID
-- consumption monitoring.
--
-- Requires: install.sql must be run first (creates tables and core functions).
--
-- Install: psql --single-transaction -f autovacuum_control.sql
-- =============================================================================

-- Verify core is installed
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM flight_recorder.config WHERE key = 'schema_version') THEN
        RAISE EXCEPTION 'Flight Recorder core not installed. Run install.sql first.';
    END IF;
END $$;

CREATE SCHEMA IF NOT EXISTS flight_recorder_reporting;

-- =============================================================================
-- Vacuum Control Helper Functions (flight_recorder schema)
-- =============================================================================

-- Calculates the rate of dead tuple accumulation over a time window
-- Returns tuples per second, or NULL if insufficient data
CREATE OR REPLACE FUNCTION flight_recorder.dead_tuple_growth_rate(
    p_relid OID,
    p_window INTERVAL
)
RETURNS NUMERIC
LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_first_snapshot RECORD;
    v_last_snapshot RECORD;
    v_delta_tuples BIGINT;
    v_delta_seconds NUMERIC;
BEGIN
    -- Get earliest snapshot within window
    SELECT ts.n_dead_tup, s.captured_at
    INTO v_first_snapshot
    FROM flight_recorder.table_snapshots ts
    JOIN flight_recorder.snapshots s ON s.id = ts.snapshot_id
    WHERE ts.relid = p_relid
      AND s.captured_at >= now() - p_window
    ORDER BY s.captured_at ASC
    LIMIT 1;

    -- Get latest snapshot
    SELECT ts.n_dead_tup, s.captured_at
    INTO v_last_snapshot
    FROM flight_recorder.table_snapshots ts
    JOIN flight_recorder.snapshots s ON s.id = ts.snapshot_id
    WHERE ts.relid = p_relid
      AND s.captured_at >= now() - p_window
    ORDER BY s.captured_at DESC
    LIMIT 1;

    -- Need at least 2 distinct snapshots
    IF v_first_snapshot.captured_at IS NULL OR v_last_snapshot.captured_at IS NULL
       OR v_first_snapshot.captured_at = v_last_snapshot.captured_at THEN
        RETURN NULL;
    END IF;

    v_delta_tuples := COALESCE(v_last_snapshot.n_dead_tup, 0) - COALESCE(v_first_snapshot.n_dead_tup, 0);
    v_delta_seconds := EXTRACT(EPOCH FROM (v_last_snapshot.captured_at - v_first_snapshot.captured_at));

    IF v_delta_seconds <= 0 THEN
        RETURN NULL;
    END IF;

    RETURN ROUND(v_delta_tuples::numeric / v_delta_seconds, 4);
END;
$$;
COMMENT ON FUNCTION flight_recorder.dead_tuple_growth_rate(OID, INTERVAL) IS 'Returns dead tuple growth rate (tuples/second) for a table over a time window';

-- Estimates time until a dead tuple budget is exhausted based on current growth rate
CREATE OR REPLACE FUNCTION flight_recorder.time_to_budget_exhaustion(
    p_relid OID,
    p_budget BIGINT
)
RETURNS INTERVAL
LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_current_dead_tuples BIGINT;
    v_growth_rate NUMERIC;
    v_remaining_budget BIGINT;
    v_seconds_to_exhaustion NUMERIC;
BEGIN
    -- Get current dead tuple count
    SELECT ts.n_dead_tup
    INTO v_current_dead_tuples
    FROM flight_recorder.table_snapshots ts
    JOIN flight_recorder.snapshots s ON s.id = ts.snapshot_id
    WHERE ts.relid = p_relid
    ORDER BY s.captured_at DESC
    LIMIT 1;

    IF v_current_dead_tuples IS NULL THEN
        RETURN NULL;
    END IF;

    -- Get growth rate over last hour
    v_growth_rate := flight_recorder.dead_tuple_growth_rate(p_relid, '1 hour'::interval);

    -- If no growth rate data or rate is zero/negative, can't estimate
    IF v_growth_rate IS NULL OR v_growth_rate <= 0 THEN
        RETURN NULL;
    END IF;

    v_remaining_budget := p_budget - v_current_dead_tuples;

    -- Already over budget
    IF v_remaining_budget <= 0 THEN
        RETURN '0 seconds'::interval;
    END IF;

    v_seconds_to_exhaustion := v_remaining_budget::numeric / v_growth_rate;

    RETURN make_interval(secs => v_seconds_to_exhaustion);
END;
$$;
COMMENT ON FUNCTION flight_recorder.time_to_budget_exhaustion(OID, BIGINT) IS 'Estimates time until dead tuple budget is exhausted based on growth rate';

-- =============================================================================
-- Vacuum Control Enhancements (v2.8)
-- =============================================================================

-- Returns table-specific autovacuum settings, falling back to global defaults
CREATE OR REPLACE FUNCTION flight_recorder._get_table_autovacuum_settings(
    p_relid OID
)
RETURNS TABLE(
    scale_factor        NUMERIC,
    threshold           INTEGER,
    enabled             BOOLEAN,
    source              TEXT
)
LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_reloptions TEXT[];
    v_opt TEXT;
    v_scale_factor NUMERIC;
    v_threshold INTEGER;
    v_enabled BOOLEAN;
    v_source TEXT := 'global';
BEGIN
    -- Get global defaults
    SELECT setting::numeric INTO v_scale_factor
    FROM pg_settings WHERE name = 'autovacuum_vacuum_scale_factor';
    v_scale_factor := COALESCE(v_scale_factor, 0.2);

    SELECT setting::integer INTO v_threshold
    FROM pg_settings WHERE name = 'autovacuum_vacuum_threshold';
    v_threshold := COALESCE(v_threshold, 50);

    v_enabled := true;

    -- Check table-specific reloptions
    SELECT c.reloptions INTO v_reloptions
    FROM pg_class c
    WHERE c.oid = p_relid;

    IF v_reloptions IS NOT NULL THEN
        FOREACH v_opt IN ARRAY v_reloptions LOOP
            IF v_opt LIKE 'autovacuum_vacuum_scale_factor=%' THEN
                v_scale_factor := substring(v_opt from '=(.*)$')::numeric;
                v_source := 'table';
            ELSIF v_opt LIKE 'autovacuum_vacuum_threshold=%' THEN
                v_threshold := substring(v_opt from '=(.*)$')::integer;
                v_source := 'table';
            ELSIF v_opt LIKE 'autovacuum_enabled=%' THEN
                v_enabled := substring(v_opt from '=(.*)$')::boolean;
                v_source := 'table';
            END IF;
        END LOOP;
    END IF;

    RETURN QUERY SELECT v_scale_factor, v_threshold, v_enabled, v_source;
END;
$$;
COMMENT ON FUNCTION flight_recorder._get_table_autovacuum_settings(OID) IS 'Returns autovacuum settings for a table, with fallback to global defaults';

-- Calculates dead tuple trend (slope) using linear regression over a time window
CREATE OR REPLACE FUNCTION flight_recorder.dead_tuple_trend(
    p_relid OID,
    p_window INTERVAL
)
RETURNS NUMERIC
LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_slope NUMERIC;
    v_count INTEGER;
BEGIN
    -- Use linear regression to determine trend
    SELECT
        count(*),
        regr_slope(n_dead_tup::numeric, EXTRACT(EPOCH FROM s.captured_at))
    INTO v_count, v_slope
    FROM flight_recorder.table_snapshots ts
    JOIN flight_recorder.snapshots s ON s.id = ts.snapshot_id
    WHERE ts.relid = p_relid
      AND s.captured_at >= now() - p_window
      AND ts.n_dead_tup IS NOT NULL;

    -- Need at least 2 points for meaningful regression
    IF v_count < 2 THEN
        RETURN NULL;
    END IF;

    -- Return tuples per second (slope of regression line)
    RETURN ROUND(v_slope, 4);
END;
$$;
COMMENT ON FUNCTION flight_recorder.dead_tuple_trend(OID, INTERVAL) IS 'Returns dead tuple accumulation trend (tuples/second) using linear regression';

-- Determines operating mode for a table (normal, catch_up, safety)
CREATE OR REPLACE FUNCTION flight_recorder.vacuum_control_mode(
    p_relid OID
)
RETURNS TABLE(
    mode        TEXT,
    reason      TEXT,
    entered_at  TIMESTAMPTZ,
    evidence    TEXT
)
LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_exists BOOLEAN;
    v_xid_age INTEGER;
    v_freeze_max_age BIGINT;
    v_xid_threshold BIGINT;
    v_dead_trend NUMERIC;
    v_time_to_exhaust INTERVAL;
    v_budget_hours INTEGER;
    v_has_blocking_txn BOOLEAN;
    v_current_mode TEXT;
    v_mode_entered TIMESTAMPTZ;
BEGIN
    -- Check if table exists
    SELECT EXISTS(SELECT 1 FROM pg_class WHERE oid = p_relid) INTO v_exists;
    IF NOT v_exists THEN
        RETURN QUERY SELECT NULL::TEXT, NULL::TEXT, NULL::TIMESTAMPTZ, NULL::TEXT;
        RETURN;
    END IF;

    -- Get current state if exists
    SELECT vcs.operating_mode, vcs.mode_entered_at
    INTO v_current_mode, v_mode_entered
    FROM flight_recorder.vacuum_control_state vcs
    WHERE vcs.relid = p_relid;

    v_current_mode := COALESCE(v_current_mode, 'normal');
    v_mode_entered := COALESCE(v_mode_entered, now());

    -- Get freeze_max_age for XID calculations
    SELECT setting::bigint INTO v_freeze_max_age
    FROM pg_settings WHERE name = 'autovacuum_freeze_max_age';
    v_freeze_max_age := COALESCE(v_freeze_max_age, 200000000);
    v_xid_threshold := (v_freeze_max_age * 0.5)::bigint;  -- 50% of freeze_max_age

    -- Check XID age
    SELECT age(c.relfrozenxid)::integer INTO v_xid_age
    FROM pg_class c
    WHERE c.oid = p_relid;

    -- SAFETY MODE: XID age approaching wraparound
    IF COALESCE(v_xid_age, 0) > v_xid_threshold THEN
        RETURN QUERY SELECT
            'safety'::TEXT,
            'XID age exceeds 50% of autovacuum_freeze_max_age'::TEXT,
            CASE WHEN v_current_mode = 'safety' THEN v_mode_entered ELSE now() END,
            format('XID age: %s, threshold: %s', v_xid_age, v_xid_threshold)::TEXT;
        RETURN;
    END IF;

    -- Check for blocking transactions
    SELECT EXISTS(
        SELECT 1 FROM pg_stat_activity
        WHERE state = 'idle in transaction'
          AND now() - xact_start > interval '30 minutes'
    ) INTO v_has_blocking_txn;

    -- SAFETY MODE: Long-running idle transactions blocking vacuum
    IF v_has_blocking_txn THEN
        RETURN QUERY SELECT
            'safety'::TEXT,
            'Long-running idle transactions may be blocking vacuum'::TEXT,
            CASE WHEN v_current_mode = 'safety' THEN v_mode_entered ELSE now() END,
            'Idle in transaction sessions older than 30 minutes detected'::TEXT;
        RETURN;
    END IF;

    -- Check dead tuple trend for catch-up mode
    v_dead_trend := flight_recorder.dead_tuple_trend(p_relid, '1 hour'::interval);

    -- Get budget hours config
    v_budget_hours := COALESCE(
        flight_recorder._get_config('vacuum_control_catchup_budget_hours', '4')::integer,
        4
    );

    -- Get time to budget exhaustion
    v_time_to_exhaust := flight_recorder.time_to_budget_exhaustion(
        p_relid,
        (SELECT COALESCE(ts.reltuples, ts.n_live_tup, 0) *
                flight_recorder._get_config('vacuum_control_dead_tuple_budget_pct', '5')::numeric / 100
         FROM flight_recorder.table_snapshots ts
         JOIN flight_recorder.snapshots s ON s.id = ts.snapshot_id
         WHERE ts.relid = p_relid
         ORDER BY s.captured_at DESC LIMIT 1)::bigint
    );

    -- CATCH_UP MODE: Dead tuples growing and budget exhaustion imminent
    IF v_dead_trend IS NOT NULL AND v_dead_trend > 0
       AND v_time_to_exhaust IS NOT NULL
       AND v_time_to_exhaust < make_interval(hours => v_budget_hours) THEN
        RETURN QUERY SELECT
            'catch_up'::TEXT,
            'Dead tuples growing, budget exhaustion imminent'::TEXT,
            CASE WHEN v_current_mode = 'catch_up' THEN v_mode_entered ELSE now() END,
            format('Trend: %s tuples/sec, time to exhaustion: %s', v_dead_trend, v_time_to_exhaust)::TEXT;
        RETURN;
    END IF;

    -- NORMAL MODE: Default steady-state
    RETURN QUERY SELECT
        'normal'::TEXT,
        'Vacuum keeping up with workload'::TEXT,
        CASE WHEN v_current_mode = 'normal' THEN v_mode_entered ELSE now() END,
        NULL::TEXT;
END;
$$;
COMMENT ON FUNCTION flight_recorder.vacuum_control_mode(OID) IS 'Determines vacuum operating mode (normal/catch_up/safety) for a table based on XID age and dead tuple trends';

-- Computes recommended autovacuum_vacuum_scale_factor based on control law
CREATE OR REPLACE FUNCTION flight_recorder.compute_recommended_scale_factor(
    p_relid OID
)
RETURNS TABLE(
    current_scale_factor        NUMERIC,
    recommended_scale_factor    NUMERIC,
    change_pct                  NUMERIC,
    rationale                   TEXT
)
LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_exists BOOLEAN;
    v_reltuples BIGINT;
    v_n_dead_tup BIGINT;
    v_current_sf NUMERIC;
    v_threshold INTEGER;
    v_budget_pct NUMERIC;
    v_min_sf NUMERIC;
    v_max_sf NUMERIC;
    v_dead_budget BIGINT;
    v_recommended_sf NUMERIC;
    v_change_pct NUMERIC;
    v_rationale TEXT;
BEGIN
    -- Check if table exists
    SELECT EXISTS(SELECT 1 FROM pg_class WHERE oid = p_relid) INTO v_exists;
    IF NOT v_exists THEN
        RETURN QUERY SELECT NULL::NUMERIC, NULL::NUMERIC, NULL::NUMERIC, NULL::TEXT;
        RETURN;
    END IF;

    -- Get current settings
    SELECT scale_factor, threshold INTO v_current_sf, v_threshold
    FROM flight_recorder._get_table_autovacuum_settings(p_relid);

    -- Get config values
    v_budget_pct := COALESCE(
        flight_recorder._get_config('vacuum_control_dead_tuple_budget_pct', '5')::numeric,
        5
    );
    v_min_sf := COALESCE(
        flight_recorder._get_config('vacuum_control_min_scale_factor', '0.001')::numeric,
        0.001
    );
    v_max_sf := COALESCE(
        flight_recorder._get_config('vacuum_control_max_scale_factor', '0.2')::numeric,
        0.2
    );

    -- Get current table stats
    SELECT COALESCE(ts.reltuples, ts.n_live_tup), ts.n_dead_tup
    INTO v_reltuples, v_n_dead_tup
    FROM flight_recorder.table_snapshots ts
    JOIN flight_recorder.snapshots s ON s.id = ts.snapshot_id
    WHERE ts.relid = p_relid
    ORDER BY s.captured_at DESC
    LIMIT 1;

    -- Handle missing data
    IF v_reltuples IS NULL OR v_reltuples = 0 THEN
        RETURN QUERY SELECT
            v_current_sf,
            NULL::NUMERIC,
            NULL::NUMERIC,
            'Insufficient data: no row count available'::TEXT;
        RETURN;
    END IF;

    -- Calculate dead tuple budget
    v_dead_budget := (v_reltuples * v_budget_pct / 100)::bigint;

    -- Control law: scale_factor = (dead_budget - threshold) / reltuples
    -- This ensures vacuum triggers when dead tuples reach budget
    IF v_dead_budget > v_threshold THEN
        v_recommended_sf := (v_dead_budget - v_threshold)::numeric / v_reltuples;
    ELSE
        v_recommended_sf := v_min_sf;
    END IF;

    -- Clamp to bounds
    v_recommended_sf := GREATEST(v_min_sf, LEAST(v_max_sf, v_recommended_sf));
    v_recommended_sf := ROUND(v_recommended_sf, 4);

    -- Calculate change percentage
    IF v_current_sf > 0 THEN
        v_change_pct := ROUND(((v_recommended_sf - v_current_sf) / v_current_sf) * 100, 1);
    ELSE
        v_change_pct := NULL;
    END IF;

    -- Build rationale
    v_rationale := format(
        'Budget: %s%% of %s rows = %s dead tuples. Current threshold triggers at %s + %s%% = %s rows.',
        v_budget_pct, v_reltuples, v_dead_budget,
        v_threshold, ROUND(v_current_sf * 100, 2),
        v_threshold + ROUND(v_current_sf * v_reltuples)
    );

    RETURN QUERY SELECT v_current_sf, v_recommended_sf, v_change_pct, v_rationale;
END;
$$;
COMMENT ON FUNCTION flight_recorder.compute_recommended_scale_factor(OID) IS 'Computes recommended autovacuum_vacuum_scale_factor to maintain dead tuple budget';

-- Classifies vacuum failure mode for diagnostic purposes
CREATE OR REPLACE FUNCTION flight_recorder.vacuum_diagnostic(
    p_relid OID
)
RETURNS TABLE(
    classification  TEXT,
    evidence        TEXT,
    confidence      TEXT,
    likely_cause    TEXT,
    mitigation      TEXT,
    mitigation_sql  TEXT
)
LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_exists BOOLEAN;
    v_schemaname TEXT;
    v_relname TEXT;
    v_n_dead_tup BIGINT;
    v_autovacuum_count BIGINT;
    v_last_autovacuum TIMESTAMPTZ;
    v_vacuum_running BOOLEAN;
    v_dead_trend NUMERIC;
    v_has_blocking_txn BOOLEAN;
    v_autovacuum_workers INTEGER;
    v_max_workers INTEGER;
    v_classification TEXT;
    v_evidence TEXT;
    v_confidence TEXT;
    v_likely_cause TEXT;
    v_mitigation TEXT;
    v_mitigation_sql TEXT;
BEGIN
    -- Check if table exists
    SELECT EXISTS(SELECT 1 FROM pg_class WHERE oid = p_relid) INTO v_exists;
    IF NOT v_exists THEN
        RETURN QUERY SELECT NULL::TEXT, NULL::TEXT, NULL::TEXT, NULL::TEXT, NULL::TEXT, NULL::TEXT;
        RETURN;
    END IF;

    -- Get table name
    SELECT n.nspname, c.relname INTO v_schemaname, v_relname
    FROM pg_class c
    JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE c.oid = p_relid;

    -- Get latest stats
    SELECT ts.n_dead_tup, ts.autovacuum_count, ts.last_autovacuum, ts.vacuum_running
    INTO v_n_dead_tup, v_autovacuum_count, v_last_autovacuum, v_vacuum_running
    FROM flight_recorder.table_snapshots ts
    JOIN flight_recorder.snapshots s ON s.id = ts.snapshot_id
    WHERE ts.relid = p_relid
    ORDER BY s.captured_at DESC
    LIMIT 1;

    -- Get dead tuple trend
    v_dead_trend := flight_recorder.dead_tuple_trend(p_relid, '1 hour'::interval);

    -- Check for blocking transactions
    SELECT EXISTS(
        SELECT 1 FROM pg_stat_activity
        WHERE state = 'idle in transaction'
          AND now() - xact_start > interval '10 minutes'
    ) INTO v_has_blocking_txn;

    -- Get autovacuum worker counts
    SELECT count(*)::integer INTO v_autovacuum_workers
    FROM pg_stat_activity
    WHERE backend_type = 'autovacuum worker';

    SELECT setting::integer INTO v_max_workers
    FROM pg_settings WHERE name = 'autovacuum_max_workers';
    v_max_workers := COALESCE(v_max_workers, 3);

    -- Classification logic
    IF v_has_blocking_txn THEN
        -- BLOCKED: Long-running transactions preventing vacuum progress
        v_classification := 'BLOCKED';
        v_evidence := 'Long-running idle in transaction sessions detected';
        v_confidence := 'high';
        v_likely_cause := 'Idle transactions holding back vacuum horizon';
        v_mitigation := 'Identify and terminate idle transactions, consider idle_in_transaction_session_timeout';
        v_mitigation_sql := format(
            'SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE state = ''idle in transaction'' AND now() - xact_start > interval ''30 minutes'';'
        );
    ELSIF v_vacuum_running AND v_dead_trend IS NOT NULL AND v_dead_trend > 0 THEN
        -- RUNNING_BUT_LOSING: Vacuum running but not keeping up
        v_classification := 'RUNNING_BUT_LOSING';
        v_evidence := format('Vacuum running but dead tuples still growing at %s/sec', v_dead_trend);
        v_confidence := 'medium';
        v_likely_cause := 'Vacuum throughput insufficient for workload';
        v_mitigation := 'Increase autovacuum_vacuum_cost_limit or reduce autovacuum_vacuum_cost_delay';
        v_mitigation_sql := 'ALTER SYSTEM SET autovacuum_vacuum_cost_limit = 2000; SELECT pg_reload_conf();';
    ELSIF v_autovacuum_workers >= v_max_workers AND v_dead_trend IS NOT NULL AND v_dead_trend > 0 THEN
        -- NOT_SCHEDULED: Workers saturated, table waiting in queue
        v_classification := 'NOT_SCHEDULED';
        v_evidence := format('All %s autovacuum workers busy, dead tuples growing', v_max_workers);
        v_confidence := 'medium';
        v_likely_cause := 'autovacuum_max_workers too low for workload';
        v_mitigation := 'Increase autovacuum_max_workers or tune scale_factor to reduce vacuum frequency';
        v_mitigation_sql := 'ALTER SYSTEM SET autovacuum_max_workers = 6; SELECT pg_reload_conf();';
    ELSIF COALESCE(v_n_dead_tup, 0) = 0 OR (v_dead_trend IS NULL OR v_dead_trend <= 0) THEN
        -- HEALTHY: No dead tuple accumulation
        v_classification := 'HEALTHY';
        v_evidence := 'Dead tuples stable or decreasing';
        v_confidence := 'high';
        v_likely_cause := 'Vacuum keeping up with workload';
        v_mitigation := 'No action required';
        v_mitigation_sql := NULL;
    ELSE
        -- NOT_SCHEDULED: Default when dead tuples growing but no obvious cause
        v_classification := 'NOT_SCHEDULED';
        v_evidence := format('Dead tuples: %s, trend: %s/sec, last vacuum: %s',
                            v_n_dead_tup, COALESCE(v_dead_trend::text, 'unknown'),
                            COALESCE(v_last_autovacuum::text, 'never'));
        v_confidence := 'low';
        v_likely_cause := 'Table not reaching vacuum threshold or autovacuum disabled';
        v_mitigation := 'Lower autovacuum_vacuum_scale_factor for this table';
        IF v_schemaname IS NOT NULL AND v_relname IS NOT NULL THEN
            v_mitigation_sql := format(
                'ALTER TABLE %I.%I SET (autovacuum_vacuum_scale_factor = 0.05);',
                v_schemaname, v_relname
            );
        END IF;
    END IF;

    RETURN QUERY SELECT v_classification, v_evidence, v_confidence, v_likely_cause, v_mitigation, v_mitigation_sql;
END;
$$;
COMMENT ON FUNCTION flight_recorder.vacuum_diagnostic(OID) IS 'Classifies vacuum failure mode (NOT_SCHEDULED/RUNNING_BUT_LOSING/BLOCKED/HEALTHY) with actionable guidance';

-- Main vacuum control report function
CREATE OR REPLACE FUNCTION flight_recorder.vacuum_control_report(
    p_start_time TIMESTAMPTZ,
    p_end_time TIMESTAMPTZ
)
RETURNS TABLE(
    schemaname                  TEXT,
    relname                     TEXT,
    relid                       OID,
    operating_mode              TEXT,
    mode_reason                 TEXT,
    diagnostic_classification   TEXT,
    diagnostic_confidence       TEXT,
    current_scale_factor        NUMERIC,
    recommended_scale_factor    NUMERIC,
    change_pct                  NUMERIC,
    should_recommend            BOOLEAN,
    last_recommendation_at      TIMESTAMPTZ,
    alter_table_sql             TEXT
)
LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_enabled BOOLEAN;
    v_hysteresis_pct NUMERIC;
    v_rate_limit_minutes INTEGER;
BEGIN
    -- Check if feature is enabled
    v_enabled := COALESCE(
        flight_recorder._get_config('vacuum_control_enabled', 'true')::boolean,
        true
    );

    IF NOT v_enabled THEN
        RETURN;
    END IF;

    -- Get config values
    v_hysteresis_pct := COALESCE(
        flight_recorder._get_config('vacuum_control_hysteresis_pct', '25')::numeric,
        25
    );
    v_rate_limit_minutes := COALESCE(
        flight_recorder._get_config('vacuum_control_rate_limit_minutes', '60')::integer,
        60
    );

    RETURN QUERY
    WITH latest_snapshots AS (
        SELECT DISTINCT ON (ts.relid)
            ts.relid,
            ts.schemaname,
            ts.relname,
            ts.n_dead_tup,
            ts.reltuples,
            ts.n_live_tup
        FROM flight_recorder.table_snapshots ts
        JOIN flight_recorder.snapshots s ON s.id = ts.snapshot_id
        WHERE s.captured_at BETWEEN p_start_time AND p_end_time
        ORDER BY ts.relid, s.captured_at DESC
    ),
    mode_info AS (
        SELECT
            ls.relid,
            (flight_recorder.vacuum_control_mode(ls.relid)).*
        FROM latest_snapshots ls
    ),
    diag_info AS (
        SELECT
            ls.relid,
            (flight_recorder.vacuum_diagnostic(ls.relid)).*
        FROM latest_snapshots ls
    ),
    scale_info AS (
        SELECT
            ls.relid,
            (flight_recorder.compute_recommended_scale_factor(ls.relid)).*
        FROM latest_snapshots ls
    ),
    state_info AS (
        SELECT
            vcs.relid,
            vcs.last_recommendation_at,
            vcs.last_recommended_scale_factor
        FROM flight_recorder.vacuum_control_state vcs
    )
    SELECT
        ls.schemaname,
        ls.relname,
        ls.relid,
        mi.mode AS operating_mode,
        mi.reason AS mode_reason,
        di.classification AS diagnostic_classification,
        di.confidence AS diagnostic_confidence,
        si.current_scale_factor,
        si.recommended_scale_factor,
        si.change_pct,
        -- Should recommend: passes hysteresis AND rate limit
        CASE
            WHEN si.recommended_scale_factor IS NULL THEN false
            WHEN ABS(COALESCE(si.change_pct, 0)) < v_hysteresis_pct THEN false
            WHEN sti.last_recommendation_at IS NOT NULL
                 AND sti.last_recommendation_at > now() - make_interval(mins => v_rate_limit_minutes)
                 THEN false
            ELSE true
        END AS should_recommend,
        sti.last_recommendation_at,
        -- Generate ALTER TABLE SQL
        CASE
            WHEN si.recommended_scale_factor IS NOT NULL
                 AND ABS(COALESCE(si.change_pct, 0)) >= v_hysteresis_pct
                 AND ls.schemaname IS NOT NULL
                 AND ls.relname IS NOT NULL
            THEN format(
                'ALTER TABLE %I.%I SET (autovacuum_vacuum_scale_factor = %s);',
                ls.schemaname, ls.relname, si.recommended_scale_factor
            )
            ELSE NULL
        END AS alter_table_sql
    FROM latest_snapshots ls
    LEFT JOIN mode_info mi ON mi.relid = ls.relid
    LEFT JOIN diag_info di ON di.relid = ls.relid
    LEFT JOIN scale_info si ON si.relid = ls.relid
    LEFT JOIN state_info sti ON sti.relid = ls.relid
    WHERE mi.mode IS NOT NULL
    ORDER BY
        CASE mi.mode
            WHEN 'safety' THEN 1
            WHEN 'catch_up' THEN 2
            ELSE 3
        END,
        COALESCE(ls.n_dead_tup, 0) DESC;
END;
$$;
COMMENT ON FUNCTION flight_recorder.vacuum_control_report(TIMESTAMPTZ, TIMESTAMPTZ) IS 'Returns vacuum control recommendations for all monitored tables with hysteresis and rate limiting';

-- =============================================================================
-- Autovacuum Observer Analysis Functions (flight_recorder_reporting schema)
-- =============================================================================

-- Calculates the rate of dead tuple accumulation over a time window
-- Returns tuples per second, or NULL if insufficient data
CREATE OR REPLACE FUNCTION flight_recorder_reporting.dead_tuple_growth_rate(
    p_relid OID,
    p_window INTERVAL
)
RETURNS NUMERIC
LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_first_snapshot RECORD;
    v_last_snapshot RECORD;
    v_delta_tuples BIGINT;
    v_delta_seconds NUMERIC;
BEGIN
    -- Get earliest snapshot within window
    SELECT ts.n_dead_tup, s.captured_at
    INTO v_first_snapshot
    FROM flight_recorder.table_snapshots ts
    JOIN flight_recorder.snapshots s ON s.id = ts.snapshot_id
    WHERE ts.relid = p_relid
      AND s.captured_at >= now() - p_window
    ORDER BY s.captured_at ASC
    LIMIT 1;

    -- Get latest snapshot
    SELECT ts.n_dead_tup, s.captured_at
    INTO v_last_snapshot
    FROM flight_recorder.table_snapshots ts
    JOIN flight_recorder.snapshots s ON s.id = ts.snapshot_id
    WHERE ts.relid = p_relid
      AND s.captured_at >= now() - p_window
    ORDER BY s.captured_at DESC
    LIMIT 1;

    -- Need at least 2 distinct snapshots
    IF v_first_snapshot.captured_at IS NULL OR v_last_snapshot.captured_at IS NULL
       OR v_first_snapshot.captured_at = v_last_snapshot.captured_at THEN
        RETURN NULL;
    END IF;

    v_delta_tuples := COALESCE(v_last_snapshot.n_dead_tup, 0) - COALESCE(v_first_snapshot.n_dead_tup, 0);
    v_delta_seconds := EXTRACT(EPOCH FROM (v_last_snapshot.captured_at - v_first_snapshot.captured_at));

    IF v_delta_seconds <= 0 THEN
        RETURN NULL;
    END IF;

    RETURN ROUND(v_delta_tuples::numeric / v_delta_seconds, 4);
END;
$$;
COMMENT ON FUNCTION flight_recorder_reporting.dead_tuple_growth_rate(OID, INTERVAL) IS 'Returns dead tuple growth rate (tuples/second) for a table over a time window';

-- Calculates the rate of table size growth in bytes per second over a time window
-- Useful for detecting bloat accumulation between vacuums
CREATE OR REPLACE FUNCTION flight_recorder_reporting.table_size_growth_rate(
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
COMMENT ON FUNCTION flight_recorder_reporting.table_size_growth_rate(OID, INTERVAL) IS 'Returns table size growth rate (bytes/second) for a table over a time window. Useful for detecting bloat accumulation.';

-- Estimates table bloat without requiring pgstattuple extension
-- Uses heuristics based on dead tuple ratio and size metrics
-- Returns estimated bloat percentage and wasted bytes
CREATE OR REPLACE FUNCTION flight_recorder_reporting.estimate_table_bloat(
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
            COALESCE(ts.schemaname, split_part(ts.relid::regclass::text, '.', 1)) AS schemaname,
            COALESCE(ts.relname, split_part(ts.relid::regclass::text, '.', 2)) AS relname,
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
COMMENT ON FUNCTION flight_recorder_reporting.estimate_table_bloat(OID) IS 'Estimates table bloat without pgstattuple. Uses dead tuple ratio and size metrics. Pass NULL or omit argument for all tables.';

-- Generates a bloat report with trends and recommendations
-- Compares current state to historical data to detect bloat accumulation
CREATE OR REPLACE FUNCTION flight_recorder_reporting.bloat_report(
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
        SELECT * FROM flight_recorder_reporting.estimate_table_bloat(NULL)
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
COMMENT ON FUNCTION flight_recorder_reporting.bloat_report(INTERVAL) IS 'Generates a bloat report with size trends and recommendations. Compares current state to historical data over the specified window.';

-- Estimates time until dead tuple budget is exhausted based on current growth rate
-- Returns interval until budget exceeded, NULL if insufficient data or no growth
CREATE OR REPLACE FUNCTION flight_recorder_reporting.time_to_budget_exhaustion(
    p_relid OID,
    p_budget BIGINT
)
RETURNS INTERVAL
LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_current_dead_tuples BIGINT;
    v_growth_rate NUMERIC;
    v_remaining_budget BIGINT;
    v_seconds_to_exhaustion NUMERIC;
BEGIN
    -- Get current dead tuple count
    SELECT ts.n_dead_tup
    INTO v_current_dead_tuples
    FROM flight_recorder.table_snapshots ts
    JOIN flight_recorder.snapshots s ON s.id = ts.snapshot_id
    WHERE ts.relid = p_relid
    ORDER BY s.captured_at DESC
    LIMIT 1;

    IF v_current_dead_tuples IS NULL THEN
        RETURN NULL;
    END IF;

    -- Get growth rate over last hour
    v_growth_rate := flight_recorder_reporting.dead_tuple_growth_rate(p_relid, '1 hour'::interval);

    -- If no growth rate data or rate is zero/negative, can't estimate
    IF v_growth_rate IS NULL OR v_growth_rate <= 0 THEN
        RETURN NULL;
    END IF;

    v_remaining_budget := p_budget - v_current_dead_tuples;

    -- Already over budget
    IF v_remaining_budget <= 0 THEN
        RETURN '0 seconds'::interval;
    END IF;

    v_seconds_to_exhaustion := v_remaining_budget::numeric / v_growth_rate;

    RETURN make_interval(secs => v_seconds_to_exhaustion);
END;
$$;
COMMENT ON FUNCTION flight_recorder_reporting.time_to_budget_exhaustion(OID, BIGINT) IS 'Estimates time until dead tuple budget is exhausted based on growth rate';

-- Calculates the rate of OID consumption over a time window
-- Returns OIDs per second based on max_catalog_oid changes in snapshots
CREATE OR REPLACE FUNCTION flight_recorder_reporting.oid_consumption_rate(
    p_window INTERVAL
)
RETURNS NUMERIC
LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_first_snapshot RECORD;
    v_last_snapshot RECORD;
    v_delta_oids BIGINT;
    v_delta_seconds NUMERIC;
BEGIN
    SELECT max_catalog_oid, captured_at
    INTO v_first_snapshot
    FROM flight_recorder.snapshots
    WHERE captured_at >= now() - p_window
      AND max_catalog_oid IS NOT NULL
    ORDER BY captured_at ASC
    LIMIT 1;

    SELECT max_catalog_oid, captured_at
    INTO v_last_snapshot
    FROM flight_recorder.snapshots
    WHERE captured_at >= now() - p_window
      AND max_catalog_oid IS NOT NULL
    ORDER BY captured_at DESC
    LIMIT 1;

    IF v_first_snapshot.captured_at IS NULL OR v_last_snapshot.captured_at IS NULL
       OR v_first_snapshot.captured_at = v_last_snapshot.captured_at THEN
        RETURN NULL;
    END IF;

    v_delta_oids := v_last_snapshot.max_catalog_oid - v_first_snapshot.max_catalog_oid;
    v_delta_seconds := EXTRACT(EPOCH FROM (v_last_snapshot.captured_at - v_first_snapshot.captured_at));

    IF v_delta_seconds <= 0 THEN
        RETURN NULL;
    END IF;

    RETURN ROUND(v_delta_oids::numeric / v_delta_seconds, 6);
END;
$$;
COMMENT ON FUNCTION flight_recorder_reporting.oid_consumption_rate(INTERVAL) IS 'Returns OID consumption rate (OIDs/second) over a time window';

-- Estimates time until OID exhaustion based on current consumption rate
-- OIDs are 32-bit unsigned integers (max ~4.3 billion) that are not recycled
CREATE OR REPLACE FUNCTION flight_recorder_reporting.time_to_oid_exhaustion()
RETURNS INTERVAL
LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_current_max_oid BIGINT;
    v_consumption_rate NUMERIC;
    v_oid_max BIGINT := 4294967295;  -- 2^32 - 1
    v_remaining_oids BIGINT;
    v_seconds_to_exhaustion NUMERIC;
BEGIN
    SELECT max_catalog_oid
    INTO v_current_max_oid
    FROM flight_recorder.snapshots
    WHERE max_catalog_oid IS NOT NULL
    ORDER BY captured_at DESC
    LIMIT 1;

    IF v_current_max_oid IS NULL THEN
        RETURN NULL;
    END IF;

    -- Use 1-hour window for rate calculation
    v_consumption_rate := flight_recorder_reporting.oid_consumption_rate('1 hour'::interval);

    IF v_consumption_rate IS NULL OR v_consumption_rate <= 0 THEN
        RETURN NULL;  -- No consumption or negative rate
    END IF;

    v_remaining_oids := v_oid_max - v_current_max_oid;

    IF v_remaining_oids <= 0 THEN
        RETURN '0 seconds'::interval;
    END IF;

    v_seconds_to_exhaustion := v_remaining_oids::numeric / v_consumption_rate;

    RETURN make_interval(secs => v_seconds_to_exhaustion);
END;
$$;
COMMENT ON FUNCTION flight_recorder_reporting.time_to_oid_exhaustion() IS 'Estimates time until OID exhaustion based on consumption rate over the last hour';
