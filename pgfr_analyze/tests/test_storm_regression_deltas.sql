-- pgTAP test: detect_query_storms() and detect_regressions() must use
-- delta columns, not cumulative counters.
--
-- Bug: both functions use SUM(ss.calls)/AVG(ss.calls) and
-- AVG(ss.shared_blks_hit + ...) on cumulative values from
-- pg_stat_statements, producing inflated/meaningless results.
-- Should use calls_delta and shared_blks_*_delta columns.
--
-- Strategy: insert synthetic statement_snapshots with HIGH cumulative
-- values but LOW delta values. If storm detection reports the high
-- cumulative numbers, the bug is present. If it reports low deltas
-- (or nothing at all), the fix works.

\set ON_ERROR_STOP 1
set client_min_messages to warning;

select plan(4);

-- -------------------------------------------------------------------------
-- Setup: create 2 snapshots and synthetic statement_snapshots rows
-- -------------------------------------------------------------------------
do $$
declare
    v_snap_baseline1_id integer;
    v_snap_baseline_id integer;
    v_snap_recent_id integer;
    v_snap_recent2_id integer;
begin
    -- Snapshot 1: baseline (3 days ago)
    insert into pgfr_record.snapshots (captured_at, pg_version)
    values (now() - interval '3 days', 170000)
    returning id into v_snap_baseline1_id;

    -- Snapshot 2: baseline (2 days ago) — need >= 2 days for baseline
    insert into pgfr_record.snapshots (captured_at, pg_version)
    values (now() - interval '2 days', 170000)
    returning id into v_snap_baseline_id;

    -- Snapshot 3: recent (10 minutes ago)
    insert into pgfr_record.snapshots (captured_at, pg_version)
    values (now() - interval '10 minutes', 170000)
    returning id into v_snap_recent_id;

    -- Snapshot 4: recent (5 minutes ago) — need >= 2 recent for regressions
    insert into pgfr_record.snapshots (captured_at, pg_version)
    values (now() - interval '5 minutes', 170000)
    returning id into v_snap_recent2_id;

    -- Statement snapshot for baseline day 1:
    -- High cumulative calls (1,000,000), low delta (50)
    insert into pgfr_record.statement_snapshots (
        snapshot_id, queryid, dbid, query_preview,
        calls, calls_delta,
        mean_exec_time,
        shared_blks_hit, shared_blks_read,
        shared_blks_hit_delta, shared_blks_read_delta,
        temp_blks_read, temp_blks_written,
        temp_blks_read_delta
    ) values (
        v_snap_baseline1_id, 12345, 0, 'SELECT * FROM test_table WHERE id = $1',
        1000000, 50,
        1.5,
        500000, 1000,
        100, 5,
        0, 0, 0
    );

    -- Statement snapshot for baseline day 2:
    insert into pgfr_record.statement_snapshots (
        snapshot_id, queryid, dbid, query_preview,
        calls, calls_delta,
        mean_exec_time,
        shared_blks_hit, shared_blks_read,
        shared_blks_hit_delta, shared_blks_read_delta,
        temp_blks_read, temp_blks_written,
        temp_blks_read_delta
    ) values (
        v_snap_baseline_id, 12345, 0, 'SELECT * FROM test_table WHERE id = $1',
        1000050, 50,
        1.5,
        500100, 1005,
        100, 5,
        0, 0, 0
    );

    -- Recent statement snapshots (2 samples needed for regression detection)
    -- Cumulative calls grew but delta stays at 50 (same rate as baseline)
    insert into pgfr_record.statement_snapshots (
        snapshot_id, queryid, dbid, query_preview,
        calls, calls_delta,
        mean_exec_time,
        shared_blks_hit, shared_blks_read,
        shared_blks_hit_delta, shared_blks_read_delta,
        temp_blks_read, temp_blks_written,
        temp_blks_read_delta
    ) values
    (v_snap_recent_id, 12345, 0, 'SELECT * FROM test_table WHERE id = $1',
        1000100, 50, 1.5, 500200, 1010, 100, 5, 0, 0, 0),
    (v_snap_recent2_id, 12345, 0, 'SELECT * FROM test_table WHERE id = $1',
        1000150, 50, 1.5, 500300, 1015, 100, 5, 0, 0, 0);

    perform set_config('test.recent_snap_id', v_snap_recent_id::text, false);
    perform set_config('test.recent2_snap_id', v_snap_recent2_id::text, false);
    perform set_config('test.baseline1_snap_id', v_snap_baseline1_id::text, false);
    perform set_config('test.baseline2_snap_id', v_snap_baseline_id::text, false);
end $$;

-- -------------------------------------------------------------------------
-- Test 1: detect_query_storms should not flag a steady-state query
-- -------------------------------------------------------------------------
-- With deltas: recent SUM(calls_delta) = 50, baseline AVG(calls_delta) = 50
-- Ratio = 1.0, well below the 3x threshold → no storm
-- With cumulative bug: result is unpredictable but the comparison is meaningless

select is(
    (select count(*)::int
     from pgfr_analyze.detect_query_storms(interval '1 hour', 3.0)
     where queryid = 12345),
    0,
    'detect_query_storms: steady-state query (50 calls/sample) should not be flagged as storm'
);

-- -------------------------------------------------------------------------
-- Test 2: detect_regressions should not flag stable timing
-- -------------------------------------------------------------------------
-- mean_exec_time is 1.5ms in both baseline and recent → 0% change
-- Buffer deltas are identical → 0% change
-- Should not be flagged

select is(
    (select count(*)::int
     from pgfr_analyze.detect_regressions(interval '1 hour', 50.0)
     where queryid = 12345),
    0,
    'detect_regressions: stable query (same timing + same buffer deltas) should not be flagged'
);

-- -------------------------------------------------------------------------
-- Test 3: storm detection uses calls_delta, not calls
-- Verify by checking recent_count reflects delta, not cumulative
-- -------------------------------------------------------------------------
-- Insert a genuinely stormy query: cumulative calls = 100 (low), delta = 10000 (high)
do $$
declare
    v_snap_id integer := current_setting('test.recent_snap_id')::integer;
    v_base1_id integer := current_setting('test.baseline1_snap_id')::integer;
    v_base2_id integer := current_setting('test.baseline2_snap_id')::integer;
begin
    -- Baseline: low delta (10 calls per sample)
    insert into pgfr_record.statement_snapshots (
        snapshot_id, queryid, dbid, query_preview,
        calls, calls_delta,
        mean_exec_time,
        shared_blks_hit, shared_blks_read,
        shared_blks_hit_delta, shared_blks_read_delta,
        temp_blks_read, temp_blks_written,
        temp_blks_read_delta
    ) values
    (v_base1_id, 99999, 0, 'INSERT INTO audit_log VALUES ($1)',
     100, 10, 0.5, 50, 5, 10, 2, 0, 0, 0),
    (v_base2_id, 99999, 0, 'INSERT INTO audit_log VALUES ($1)',
     110, 10, 0.5, 60, 7, 10, 2, 0, 0, 0);

    -- Recent: huge delta (10,000 calls per sample) but low cumulative (120)
    -- Two recent samples needed for regression detection (sample_count >= 2)
    insert into pgfr_record.statement_snapshots (
        snapshot_id, queryid, dbid, query_preview,
        calls, calls_delta,
        mean_exec_time,
        shared_blks_hit, shared_blks_read,
        shared_blks_hit_delta, shared_blks_read_delta,
        temp_blks_read, temp_blks_written,
        temp_blks_read_delta
    ) values
    (v_snap_id, 99999, 0, 'INSERT INTO audit_log VALUES ($1)',
        120, 10000, 0.5, 70, 9, 5000, 500, 0, 0, 0),
    (current_setting('test.recent2_snap_id')::integer, 99999, 0, 'INSERT INTO audit_log VALUES ($1)',
        130, 10000, 0.5, 80, 11, 5000, 500, 0, 0, 0);
end $$;

-- With deltas: recent SUM(calls_delta) = 10000, baseline AVG(calls_delta) = 10
-- Ratio = 1000x → definitely a storm
-- With cumulative bug: recent SUM(calls) = 120, baseline AVG(calls) = 105
-- Ratio = 1.14x → NOT detected as storm (false negative)

select ok(
    (select count(*)::int
     from pgfr_analyze.detect_query_storms(interval '1 hour', 3.0)
     where queryid = 99999) > 0,
    'detect_query_storms: genuine delta spike (10000x) must be detected'
);

-- -------------------------------------------------------------------------
-- Test 4: regression detection uses buffer deltas, not cumulative
-- -------------------------------------------------------------------------
-- For queryid 99999:
-- Baseline buffer deltas: AVG(10+2) = 12 per sample
-- Recent buffer deltas: SUM(5000+500) = 5500 → massive regression
-- With cumulative: baseline AVG(50+5 + 60+7) / 2 = 61, recent = 70+9 = 79
--   → 29% increase, below 50% threshold → NOT detected

select ok(
    (select count(*)::int
     from pgfr_analyze.detect_regressions(interval '1 hour', 50.0)
     where queryid = 99999) > 0,
    'detect_regressions: genuine buffer delta spike must be detected'
);

-- -------------------------------------------------------------------------
-- Cleanup
-- -------------------------------------------------------------------------
do $$
declare
    v_snap_id integer := current_setting('test.recent_snap_id')::integer;
    v_snap2_id integer := current_setting('test.recent2_snap_id')::integer;
    v_base1_id integer := current_setting('test.baseline1_snap_id')::integer;
    v_base2_id integer := current_setting('test.baseline2_snap_id')::integer;
begin
    delete from pgfr_record.statement_snapshots
    where snapshot_id in (v_snap_id, v_snap2_id, v_base1_id, v_base2_id);
    delete from pgfr_record.snapshots
    where id in (v_snap_id, v_snap2_id, v_base1_id, v_base2_id);
end $$;

select * from finish();
