-- =============================================================================
-- pgfr_analyze pgTAP Tests - v2 Partitioned Table Reader Functions (Issue #11)
-- =============================================================================
-- Tests: v2_time_range, statement_activity_v2, table_activity_v2,
--        index_activity_v2
-- Test count: 14
-- =============================================================================

begin;
select plan(19);

-- ---------------------------------------------------------------------------
-- 1. v2_time_range: function exists
-- ---------------------------------------------------------------------------
select has_function(
    'pgfr_analyze',
    'v2_time_range',
    array['timestamp with time zone', 'timestamp with time zone'],
    'pgfr_analyze.v2_time_range(timestamptz, timestamptz) should exist'
);

-- 2. v2_time_range: ts_start is int4 (verify via pg_typeof on actual output)
select is(
    (select pg_typeof(ts_start)::text
     from pgfr_analyze.v2_time_range(
         pgfr_record.epoch(),
         pgfr_record.epoch() + interval '1 hour'
     )),
    'integer',
    'v2_time_range.ts_start should have type integer (int4)'
);

-- 3. v2_time_range: ts_end is int4
select is(
    (select pg_typeof(ts_end)::text
     from pgfr_analyze.v2_time_range(
         pgfr_record.epoch(),
         pgfr_record.epoch() + interval '1 hour'
     )),
    'integer',
    'v2_time_range.ts_end should have type integer (int4)'
);

-- 3. v2_time_range: ts_start < ts_end for a valid range
select ok(
    (select ts_start < ts_end
     from pgfr_analyze.v2_time_range(
         '2026-01-01 00:00:00+00'::timestamptz,
         '2026-01-01 01:00:00+00'::timestamptz
     )),
    'v2_time_range: ts_start must be less than ts_end for ascending range'
);

-- 4. v2_time_range: epoch anchor gives ts_start = 0 when p_start = epoch
select is(
    (select ts_start
     from pgfr_analyze.v2_time_range(
         pgfr_record.epoch(),
         pgfr_record.epoch() + interval '1 hour'
     )),
    0::int4,
    'v2_time_range: p_start = epoch() should yield ts_start = 0'
);

-- 5. v2_time_range: 1-hour window maps to exactly 3600 seconds
select is(
    (select ts_end - ts_start
     from pgfr_analyze.v2_time_range(
         pgfr_record.epoch(),
         pgfr_record.epoch() + interval '1 hour'
     )),
    3600::int4,
    'v2_time_range: 1-hour window should span exactly 3600 int4 seconds'
);

-- ---------------------------------------------------------------------------
-- 6. statement_activity_v2: function exists
-- ---------------------------------------------------------------------------
select has_function(
    'pgfr_analyze',
    'statement_activity_v2',
    array['timestamp with time zone', 'timestamp with time zone', 'integer'],
    'pgfr_analyze.statement_activity_v2(timestamptz, timestamptz, integer) should exist'
);

-- 7. statement_activity_v2: executes without error on empty range
select lives_ok(
    $$select * from pgfr_analyze.statement_activity_v2(
          now() - interval '1 hour', now())$$,
    'statement_activity_v2: should execute without error on current time range'
);

-- 8. statement_activity_v2: respects p_limit
select ok(
    (select count(*) <= 5
     from pgfr_analyze.statement_activity_v2(
         pgfr_record.epoch(),
         pgfr_record.epoch() + interval '1 year',
         5
     )),
    'statement_activity_v2: result count must not exceed p_limit'
);

-- ---------------------------------------------------------------------------
-- 9. table_activity_v2: function exists
-- ---------------------------------------------------------------------------
select has_function(
    'pgfr_analyze',
    'table_activity_v2',
    array['timestamp with time zone', 'timestamp with time zone', 'integer'],
    'pgfr_analyze.table_activity_v2(timestamptz, timestamptz, integer) should exist'
);

-- 10. table_activity_v2: executes without error on empty range
select lives_ok(
    $$select * from pgfr_analyze.table_activity_v2(
          now() - interval '1 hour', now())$$,
    'table_activity_v2: should execute without error on current time range'
);

-- 11. table_activity_v2: respects p_limit
select ok(
    (select count(*) <= 3
     from pgfr_analyze.table_activity_v2(
         pgfr_record.epoch(),
         pgfr_record.epoch() + interval '1 year',
         3
     )),
    'table_activity_v2: result count must not exceed p_limit'
);

-- ---------------------------------------------------------------------------
-- 12. index_activity_v2: function exists
-- ---------------------------------------------------------------------------
select has_function(
    'pgfr_analyze',
    'index_activity_v2',
    array['timestamp with time zone', 'timestamp with time zone', 'integer'],
    'pgfr_analyze.index_activity_v2(timestamptz, timestamptz, integer) should exist'
);

-- 13. index_activity_v2: executes without error on empty range
select lives_ok(
    $$select * from pgfr_analyze.index_activity_v2(
          now() - interval '1 hour', now())$$,
    'index_activity_v2: should execute without error on current time range'
);

-- ---------------------------------------------------------------------------
-- 14. index_activity_v2: respects p_limit
-- ---------------------------------------------------------------------------
select ok(
    (select count(*) <= 3
     from pgfr_analyze.index_activity_v2(
         pgfr_record.epoch(),
         pgfr_record.epoch() + interval '1 year',
         3
     )),
    'index_activity_v2: result count must not exceed p_limit'
);

-- ===========================================================================
-- Delta correctness tests (N1 regression guard)
-- snap_start must be the last row BEFORE the window, not first row inside.
-- ===========================================================================
--
-- Scenario: query ran before, during, and after the window.
-- Pre-window:   ts=1000, calls=100
-- In-window:    ts=2000, calls=150  (end of window)
-- Post-window:  ts=3000, calls=200  (should not affect result)
--
-- Correct delta for window [1500, 2500): calls_delta = 150 - 100 = 50
-- Wrong delta (old bug):    calls_delta = 150 - 0   = 150 (no pre-window baseline)
-- ---------------------------------------------------------------------------

do $$
declare
    v_epoch       timestamptz := pgfr_record.epoch();
    v_snap_before int4 := 1000;   -- before window
    v_snap_in     int4 := 2000;   -- inside window
    v_snap_after  int4 := 3000;   -- after window
    v_win_start   timestamptz;
    v_win_end     timestamptz;
    v_delta_calls bigint;
    v_testqid     bigint := -88881234;
    v_dbid        oid;
    v_uid         oid;
begin
    v_dbid      := (select oid from pg_database where datname = current_database());
    v_uid       := (select usesysid from pg_user where usename = current_user);
    v_win_start := v_epoch + 1500 * interval '1 second';
    v_win_end   := v_epoch + 2500 * interval '1 second';

    -- ensure partition exists for the test timestamps
    perform pgfr_record._ensure_partition('statement_snapshots_v2',
        (v_epoch + v_snap_before * interval '1 second')::date);
    perform pgfr_record._ensure_partition('statement_snapshots_v2',
        (v_epoch + v_snap_in    * interval '1 second')::date);

    -- seed pre-window baseline (calls=100)
    insert into pgfr_record.statement_snapshots_v2 (
        snapshot_id, sample_ts, queryid, userid, dbid, toplevel,
        calls, total_exec_time, rows, shared_blks_hit, shared_blks_read,
        temp_blks_written, pgss_dealloc_warning
    ) values (-1, v_snap_before, v_testqid, v_uid, v_dbid, true,
              100, 1000.0, 100, 500, 10, 0, false);

    -- seed in-window row (calls=150)
    insert into pgfr_record.statement_snapshots_v2 (
        snapshot_id, sample_ts, queryid, userid, dbid, toplevel,
        calls, total_exec_time, rows, shared_blks_hit, shared_blks_read,
        temp_blks_written, pgss_dealloc_warning
    ) values (-2, v_snap_in, v_testqid, v_uid, v_dbid, true,
              150, 1600.0, 150, 750, 15, 0, false);

    -- query the reader for the window [1500, 2500)
    select calls_delta into v_delta_calls
    from pgfr_analyze.statement_activity_v2(v_win_start, v_win_end, 100)
    where queryid = v_testqid;

    if v_delta_calls is null then
        raise exception
            'R1: statement_activity_v2 returned no row for test queryid — snap_start fix may have broken join';
    end if;

    if v_delta_calls <> 50 then
        raise exception
            'R1: calls_delta = % (expected 50). snap_start bug: pre-window baseline not used.',
            v_delta_calls;
    end if;
end $$;

select ok(true, 'R1: statement_activity_v2 uses pre-window baseline — calls_delta = 50 not 150 (N1 guard)');

-- ---------------------------------------------------------------------------
-- R2. table_activity_v2 delta correctness
-- Pre-window: ts=1000, n_tup_ins=200
-- In-window:  ts=2000, n_tup_ins=260
-- Expected:   n_tup_ins_delta = 60 (not 260)
-- ---------------------------------------------------------------------------
do $$
declare
    v_epoch      timestamptz := pgfr_record.epoch();
    v_win_start  timestamptz;
    v_win_end    timestamptz;
    v_delta      bigint;
    v_testrelid  oid := 99999::oid;
    v_dbid       oid;
begin
    v_dbid     := (select oid from pg_database where datname = current_database());
    v_win_start := v_epoch + 1500 * interval '1 second';
    v_win_end   := v_epoch + 2500 * interval '1 second';

    perform pgfr_record._ensure_partition('table_snapshots_v2',
        (v_epoch + 1000 * interval '1 second')::date,
        'relid, dbid, sample_ts desc');
    perform pgfr_record._ensure_partition('table_snapshots_v2',
        (v_epoch + 2000 * interval '1 second')::date,
        'relid, dbid, sample_ts desc');

    insert into pgfr_record.table_snapshots_v2 (
        snapshot_id, sample_ts, relid, dbid,
        n_tup_ins, n_tup_upd, n_tup_del, n_tup_hot_upd,
        seq_scan, idx_scan, n_live_tup, n_dead_tup, table_size_bytes
    ) values (-1, 1000, v_testrelid, v_dbid,
              200, 0, 0, 0, 0, 0, 200, 0, 8192);

    insert into pgfr_record.table_snapshots_v2 (
        snapshot_id, sample_ts, relid, dbid,
        n_tup_ins, n_tup_upd, n_tup_del, n_tup_hot_upd,
        seq_scan, idx_scan, n_live_tup, n_dead_tup, table_size_bytes
    ) values (-2, 2000, v_testrelid, v_dbid,
              260, 0, 0, 0, 0, 0, 260, 0, 8192);

    select n_tup_ins_delta into v_delta
    from pgfr_analyze.table_activity_v2(v_win_start, v_win_end, 100)
    where relid = v_testrelid;

    if v_delta is null then
        raise exception 'R2: table_activity_v2 returned no row for test relid';
    end if;
    if v_delta <> 60 then
        raise exception 'R2: n_tup_ins_delta = % (expected 60)', v_delta;
    end if;
end $$;

select ok(true, 'R2: table_activity_v2 uses pre-window baseline — n_tup_ins_delta = 60 not 260 (N1 guard)');

-- ---------------------------------------------------------------------------
-- R3. index_activity_v2 delta correctness
-- Pre-window: ts=1000, idx_scan=500
-- In-window:  ts=2000, idx_scan=580
-- Expected:   idx_scan_delta = 80 (not 580)
-- ---------------------------------------------------------------------------
do $$
declare
    v_epoch        timestamptz := pgfr_record.epoch();
    v_win_start    timestamptz;
    v_win_end      timestamptz;
    v_delta        bigint;
    v_testrelid    oid := 99998::oid;
    v_testindexid  oid := 99997::oid;
    v_dbid         oid;
begin
    v_dbid      := (select oid from pg_database where datname = current_database());
    v_win_start := v_epoch + 1500 * interval '1 second';
    v_win_end   := v_epoch + 2500 * interval '1 second';

    perform pgfr_record._ensure_partition('index_snapshots_v2',
        (v_epoch + 1000 * interval '1 second')::date,
        'indexrelid, dbid, sample_ts desc');
    perform pgfr_record._ensure_partition('index_snapshots_v2',
        (v_epoch + 2000 * interval '1 second')::date,
        'indexrelid, dbid, sample_ts desc');

    insert into pgfr_record.index_snapshots_v2 (
        snapshot_id, sample_ts, relid, indexrelid, dbid,
        idx_scan, idx_tup_read, idx_tup_fetch, index_size_bytes
    ) values (-1, 1000, v_testrelid, v_testindexid, v_dbid, 500, 5000, 4900, 16384);

    insert into pgfr_record.index_snapshots_v2 (
        snapshot_id, sample_ts, relid, indexrelid, dbid,
        idx_scan, idx_tup_read, idx_tup_fetch, index_size_bytes
    ) values (-2, 2000, v_testrelid, v_testindexid, v_dbid, 580, 5800, 5700, 16384);

    select idx_scan_delta into v_delta
    from pgfr_analyze.index_activity_v2(v_win_start, v_win_end, 100)
    where indexrelid = v_testindexid;

    if v_delta is null then
        raise exception 'R3: index_activity_v2 returned no row for test indexrelid';
    end if;
    if v_delta <> 80 then
        raise exception 'R3: idx_scan_delta = % (expected 80)', v_delta;
    end if;
end $$;

select ok(true, 'R3: index_activity_v2 uses pre-window baseline — idx_scan_delta = 80 not 580 (N1 guard)');

-- ---------------------------------------------------------------------------
-- R4. Single-tick window: delta is 0 when only one row exists (inside window)
--     With no pre-window baseline, coalesce to 0 — result is the full counter
--     value. This is expected/documented behaviour for first-ever appearance.
-- ---------------------------------------------------------------------------
do $$
declare
    v_epoch     timestamptz := pgfr_record.epoch();
    v_win_start timestamptz;
    v_win_end   timestamptz;
    v_delta     bigint;
    v_newqid    bigint := -88885678;
    v_dbid      oid;
    v_uid       oid;
begin
    v_dbid      := (select oid from pg_database where datname = current_database());
    v_uid       := (select usesysid from pg_user where usename = current_user);
    v_win_start := v_epoch + 4000 * interval '1 second';
    v_win_end   := v_epoch + 5000 * interval '1 second';

    perform pgfr_record._ensure_partition('statement_snapshots_v2',
        (v_epoch + 4500 * interval '1 second')::date);

    -- only one row, inside window, no pre-window baseline
    insert into pgfr_record.statement_snapshots_v2 (
        snapshot_id, sample_ts, queryid, userid, dbid, toplevel,
        calls, total_exec_time, rows, shared_blks_hit, shared_blks_read,
        temp_blks_written, pgss_dealloc_warning
    ) values (-3, 4500, v_newqid, v_uid, v_dbid, true,
              42, 420.0, 42, 100, 5, 0, false);

    select calls_delta into v_delta
    from pgfr_analyze.statement_activity_v2(v_win_start, v_win_end, 100)
    where queryid = v_newqid;

    -- first-ever appearance: no pre-window row, delta = calls - 0 = 42
    -- this is the documented behaviour (not a bug, just no history)
    if v_delta is null or v_delta <> 42 then
        raise exception 'R4: first-ever query delta = % (expected 42)', v_delta;
    end if;
end $$;

select ok(true, 'R4: first-ever query appearance returns calls_delta = full counter (no prior baseline)');

select * from finish();
rollback;
