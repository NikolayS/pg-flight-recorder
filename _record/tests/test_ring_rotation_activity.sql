-- pgTAP test: rotate_ring() must truncate activity_samples partitions
--
-- This test verifies that ring rotation clears activity_samples_N
-- alongside wait_samples_N, lock_samples_N, and query_map_N.
--
-- Bug: rotate_ring() truncated 3 of 4 ring tables, leaving
-- activity_samples to grow without bound (~36K rows/day).

\set ON_ERROR_STOP 1
set client_min_messages to warning;

select plan(4);

-- -------------------------------------------------------------------------
-- Setup: identify the slot that will be truncated on the NEXT rotation
-- -------------------------------------------------------------------------
do $$
declare
    v_current   smallint;
    v_num_slots smallint;
    v_next_slot smallint;
    v_truncate_slot smallint;
begin
    select current_slot, num_slots
    into v_current, v_num_slots
    from pgfr_record.ring_config
    where singleton;

    -- rotate_ring() advances to (current + 1) % num_slots
    -- then truncates (new_slot + 1) % num_slots
    v_next_slot     := (v_current + 1) % v_num_slots;
    v_truncate_slot := (v_next_slot + 1) % v_num_slots;

    -- insert a canary row into each ring table for the truncate-target slot
    execute format(
        'insert into pgfr_record.wait_samples_%s (sample_ts, datid, active_count, data, slot) '
        'values (999999, 0, 1, array[-1, 1, 0], %s)',
        v_truncate_slot, v_truncate_slot
    );

    execute format(
        'insert into pgfr_record.lock_samples_%s '
        '(sample_ts, blocked_pid, blocking_pid, lock_type, slot) '
        'values (999999, 1, 2, 1, %s)',
        v_truncate_slot, v_truncate_slot
    );

    execute format(
        'insert into pgfr_record.activity_samples_%s '
        '(sample_ts, pid, slot) '
        'values (999999, 1, %s)',
        v_truncate_slot, v_truncate_slot
    );

    -- force rotation by backdating rotated_at
    update pgfr_record.ring_config
    set rotated_at = now() - interval '3 hours'
    where singleton;

    -- store truncate_slot for later assertions
    perform set_config('test.truncate_slot', v_truncate_slot::text, false);
end $$;

-- -------------------------------------------------------------------------
-- Execute: rotate
-- -------------------------------------------------------------------------
select matches(
    pgfr_record.rotate_ring(),
    '^rotated',
    'rotate_ring() actually rotated (not skipped)'
);

-- -------------------------------------------------------------------------
-- Verify: all ring tables for the truncated slot should be empty
-- -------------------------------------------------------------------------

-- wait_samples — should be truncated
select is(
    (select count(*)::int
     from pgfr_record.wait_samples
     where slot = current_setting('test.truncate_slot')::smallint
       and sample_ts = 999999),
    0,
    'wait_samples canary row cleared after rotation'
);

-- lock_samples — should be truncated
select is(
    (select count(*)::int
     from pgfr_record.lock_samples
     where slot = current_setting('test.truncate_slot')::smallint
       and sample_ts = 999999),
    0,
    'lock_samples canary row cleared after rotation'
);

-- activity_samples — THIS is the bug: should be truncated but wasn't
select is(
    (select count(*)::int
     from pgfr_record.activity_samples
     where slot = current_setting('test.truncate_slot')::smallint
       and sample_ts = 999999),
    0,
    'activity_samples canary row cleared after rotation'
);

-- -------------------------------------------------------------------------
-- Cleanup: restore rotation time
-- -------------------------------------------------------------------------
do $$
begin
    update pgfr_record.ring_config
    set rotated_at = now()
    where singleton;
end $$;

select * from finish();
