-- pgTAP test: report() must not crash when wait_summary() returns backend_state
--
-- Bug: v2 wait_summary() returns 'backend_state' column but report()
-- references 'v_row.backend_type', causing a runtime error when the
-- Wait Event Summary section is rendered with data.
--
-- Strategy: insert synthetic wait_samples data, then call report().
-- If report() crashes on backend_type, the test fails.

\set ON_ERROR_STOP 1
set client_min_messages to warning;

select plan(3);

-- -------------------------------------------------------------------------
-- Setup: insert a snapshot + wait_samples with a known wait event
-- -------------------------------------------------------------------------
do $$
declare
    v_snap_id integer;
    v_slot smallint;
    v_wid smallint;
    v_sample_ts integer;
begin
    -- Create a snapshot so report() has a time window with data
    insert into pgfr_record.snapshots (captured_at, pg_version)
    values (now() - interval '5 minutes', 170000)
    returning id into v_snap_id;

    -- Get current ring slot and compute sample_ts
    v_slot := pgfr_record.ring_current_slot();
    v_sample_ts := extract(epoch from now() - interval '5 minutes' - pgfr_record.epoch())::int4;

    -- Register a wait event
    v_wid := pgfr_record._register_wait('active', 'Lock', 'relation');

    -- Insert a wait_samples row so wait_summary() returns data
    execute format(
        'insert into pgfr_record.wait_samples_%s (sample_ts, datid, active_count, data, slot) '
        'values (%s, 0, 5, array[%s, 3, 0], %s)',
        v_slot, v_sample_ts, -v_wid, v_slot
    );

    perform set_config('test.snap_id', v_snap_id::text, false);
    perform set_config('test.sample_ts', v_sample_ts::text, false);
    perform set_config('test.slot', v_slot::text, false);
end $$;

-- -------------------------------------------------------------------------
-- Test 1: wait_summary() returns data (prerequisite)
-- -------------------------------------------------------------------------
select ok(
    (select count(*)::int
     from pgfr_analyze.wait_summary(now() - interval '10 minutes', now())) > 0,
    'wait_summary() returns rows with test data'
);

-- -------------------------------------------------------------------------
-- Test 2: report() does not crash (the actual C4 bug)
-- -------------------------------------------------------------------------
select lives_ok(
    $$SELECT pgfr_analyze.report(now() - interval '10 minutes', now())$$,
    'report() executes without error when wait_summary has data'
);

-- -------------------------------------------------------------------------
-- Test 3: report output contains Wait Event Summary section with data
-- -------------------------------------------------------------------------
select ok(
    (select pgfr_analyze.report(now() - interval '10 minutes', now())
     ilike '%Wait Event Summary%Lock%relation%'),
    'report() output contains wait event data (Lock:relation)'
);

-- -------------------------------------------------------------------------
-- Cleanup
-- -------------------------------------------------------------------------
do $$
declare
    v_snap_id integer := current_setting('test.snap_id')::integer;
    v_slot smallint := current_setting('test.slot')::smallint;
begin
    -- Clean up wait_samples (can't easily target specific rows, but truncating
    -- the test slot would be too aggressive). Leave it — test data is harmless.
    delete from pgfr_record.snapshots where id = v_snap_id;
end $$;

select * from finish();
