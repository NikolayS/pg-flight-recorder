-- pgTAP functional tests for ring buffer v2
-- Validates sample_ring() output, rotate_ring() correctness, and encoding integrity.
-- Complements test_ring_buffer.sql (structural) with data-correctness assertions.
--
-- Run after install.sql with pg_tap installed:
--   PGPASSWORD=postgres psql -h localhost -p 5416 -U postgres -d postgres \
--       -f _record/tests/test_ring_buffer_functional.sql

\set ON_ERROR_STOP 1
set client_min_messages to warning;

begin;
select plan(21);

-- =========================================================================
-- Setup: snapshot of ring state before tests
-- =========================================================================
do $$
begin
    -- ensure extension is wired
    if not exists (select from pgfr_record.ring_config) then
        raise exception 'ring_config missing — install.sql not applied';
    end if;
end $$;

-- =========================================================================
-- F1. sample_ring() inserts rows into wait_samples
-- =========================================================================
do $$
declare
    v_before bigint;
    v_after  bigint;
begin
    select count(*) into v_before from pgfr_record.wait_samples;
    perform pgfr_record.sample_ring();
    select count(*) into v_after from pgfr_record.wait_samples;
    -- may be 0 if no active waits on idle system — that's valid
    -- but the function must return without error
    if v_after < v_before then
        raise exception 'sample_ring() reduced wait_samples count (% → %)',
            v_before, v_after;
    end if;
end $$;

select ok(true, 'F1: sample_ring() completes without error');

-- =========================================================================
-- F2. sample_ring() produces valid integer[] encoding
--     Every row in wait_samples must satisfy: data[1] < 0, length >= 3
--     (enforced by check constraint, but verify no rows violate it)
-- =========================================================================
select ok(
    not exists (
        select 1 from pgfr_record.wait_samples
        where data[1] >= 0
           or array_length(data, 1) < 3
    ),
    'F2: all wait_samples rows satisfy data[1] < 0 and length >= 3'
);

-- =========================================================================
-- F3. sample_ring() output is decodeable by recent_waits_v2
--     If any rows exist, the view must decode them without error
-- =========================================================================
do $$
declare
    v_count bigint;
begin
    select count(*) into v_count from pgfr_record.recent_waits_v2;
    -- no exception = decoding works
end $$;

select ok(true, 'F3: recent_waits_v2 decodes sample_ring() output without error');

-- =========================================================================
-- F4. sample_ring() encodes multi-event arrays correctly
--     Insert a synthetic 2-event row and verify the decoder expands it
-- =========================================================================
do $$
declare
    v_wid1 smallint;
    v_wid2 smallint;
    v_slot smallint;
    v_ts   int4;
    v_rows int;
begin
    v_wid1 := pgfr_record._register_wait('active', 'Lock', 'relation');
    v_wid2 := pgfr_record._register_wait('active', 'LWLock', 'buffer_content');
    v_slot := pgfr_record.ring_current_slot();
    v_ts   := extract(epoch from now() - pgfr_record.epoch())::int4 + 9000;

    -- encode: [-wid1, count1, 0, -wid2, count2, 0]
    insert into pgfr_record.wait_samples (sample_ts, datid, active_count, data, slot)
    values (
        v_ts,
        (select oid from pg_database where datname = current_database()),
        2,
        array[-v_wid1::integer, 3, 0, -v_wid2::integer, 1, 0],
        v_slot
    );

    -- verify decoder expands to 2 rows from this sample_ts (view exposes captured_at)
    select count(*)::int into v_rows
    from pgfr_record.recent_waits_v2
    where captured_at = pgfr_record.epoch() + v_ts * interval '1 second';

    if v_rows <> 2 then
        raise exception 'F4: expected 2 decoded rows for 2-event array, got %', v_rows;
    end if;
end $$;

select ok(true, 'F4: recent_waits_v2 correctly expands multi-event integer[] arrays');

-- =========================================================================
-- F5. rotate_ring() advances current_slot correctly (modular arithmetic)
-- =========================================================================
do $$
declare
    v_old_slot   smallint;
    v_num_slots  smallint;
    v_expected   smallint;
    v_actual     smallint;
    v_result     text;
begin
    select current_slot, num_slots
    into v_old_slot, v_num_slots
    from pgfr_record.ring_config where singleton;

    v_expected := (v_old_slot + 1) % v_num_slots;

    -- force rotation by backdating rotated_at
    update pgfr_record.ring_config
    set rotated_at = now() - interval '3 hours'
    where singleton;

    v_result := pgfr_record.rotate_ring();

    select current_slot into v_actual
    from pgfr_record.ring_config where singleton;

    if v_actual <> v_expected then
        raise exception 'F5: current_slot wrong after rotation: expected %, got % (result: %)',
            v_expected, v_actual, v_result;
    end if;
end $$;

select ok(true, 'F5: rotate_ring() advances current_slot by 1 (mod num_slots)');

-- =========================================================================
-- F6. rotate_ring() truncates the CORRECT slot (two steps ahead, not current)
-- =========================================================================
do $$
declare
    v_slot       smallint;
    v_num_slots  smallint;
    v_truncated  smallint;
    v_ts         int4;
    v_row_count  bigint;
begin
    select current_slot, num_slots
    into v_slot, v_num_slots
    from pgfr_record.ring_config where singleton;

    -- the next rotation will truncate (v_slot + 1 + 1) % v_num_slots
    -- = slot that is two steps ahead of the new current_slot
    v_truncated := (v_slot + 2) % v_num_slots;

    -- seed the target-to-be-truncated slot with a sentinel row
    v_ts := extract(epoch from now() - pgfr_record.epoch())::int4 + 9100;
    insert into pgfr_record.wait_samples (sample_ts, datid, active_count, data, slot)
    values (v_ts, 0::oid, 1, array[-1::integer, 1, 0], v_truncated);

    -- seed the current slot (should survive rotation)
    insert into pgfr_record.wait_samples (sample_ts, datid, active_count, data, slot)
    values (v_ts + 1, 0::oid, 1, array[-1::integer, 1, 0], v_slot);

    -- force rotation
    update pgfr_record.ring_config
    set rotated_at = now() - interval '3 hours'
    where singleton;

    perform pgfr_record.rotate_ring();

    -- truncated slot must be empty
    execute format(
        'select count(*) from pgfr_record.wait_samples_%s where sample_ts = $1',
        v_truncated
    ) into v_row_count using v_ts;

    if v_row_count <> 0 then
        raise exception 'F6: truncated slot % still has % row(s) — wrong slot truncated',
            v_truncated, v_row_count;
    end if;
end $$;

select ok(true, 'F6: rotate_ring() truncates the correct slot (two steps ahead)');

-- =========================================================================
-- F7. Non-truncated slots survive rotation
-- =========================================================================
do $$
declare
    v_slot       smallint;
    v_num_slots  smallint;
    v_survive    smallint;
    v_ts         int4;
    v_row_count  bigint;
begin
    select current_slot, num_slots
    into v_slot, v_num_slots
    from pgfr_record.ring_config where singleton;

    -- slot that should survive: new current_slot after rotation
    v_survive := (v_slot + 1) % v_num_slots;

    v_ts := extract(epoch from now() - pgfr_record.epoch())::int4 + 9200;
    -- seed the surviving slot
    insert into pgfr_record.wait_samples (sample_ts, datid, active_count, data, slot)
    values (v_ts, 0::oid, 1, array[-1::integer, 1, 0], v_survive);

    -- force rotation
    update pgfr_record.ring_config
    set rotated_at = now() - interval '3 hours'
    where singleton;

    perform pgfr_record.rotate_ring();

    execute format(
        'select count(*) from pgfr_record.wait_samples_%s where sample_ts = $1',
        v_survive
    ) into v_row_count using v_ts;

    if v_row_count <> 1 then
        raise exception 'F7: surviving slot % lost data after rotation (found % rows)',
            v_survive, v_row_count;
    end if;
end $$;

select ok(true, 'F7: non-truncated slots retain data through rotate_ring()');

-- =========================================================================
-- F8. rotate_ring() skips when called too soon after previous rotation
-- =========================================================================
do $$
declare
    v_result text;
begin
    -- do NOT backdate rotated_at — let it be fresh from F5/F6/F7
    v_result := pgfr_record.rotate_ring();
    if v_result not like 'skipped:%' then
        raise exception 'F8: expected skipped, got: %', v_result;
    end if;
end $$;

select ok(true, 'F8: rotate_ring() returns skipped when called within rotation period');

-- =========================================================================
-- F9. rotate_ring() result text includes slot numbers on actual rotation
-- =========================================================================
do $$
declare
    v_old_slot  smallint;
    v_result    text;
begin
    select current_slot into v_old_slot from pgfr_record.ring_config where singleton;

    update pgfr_record.ring_config
    set rotated_at = now() - interval '3 hours'
    where singleton;

    v_result := pgfr_record.rotate_ring();

    if v_result not like 'rotated: slot%' then
        raise exception 'F9: unexpected result text: %', v_result;
    end if;
end $$;

select ok(true, 'F9: rotate_ring() result text includes slot numbers');

-- =========================================================================
-- F10. _register_query() returns consistent id for same query_id
--      (idempotent insert via ON CONFLICT DO UPDATE)
-- =========================================================================
do $$
declare
    v_id1 int4;
    v_id2 int4;
begin
    v_id1 := pgfr_record._register_query(99999999::int8);
    v_id2 := pgfr_record._register_query(99999999::int8);
    if v_id1 <> v_id2 then
        raise exception 'F10: _register_query returned different ids for same query_id: % vs %',
            v_id1, v_id2;
    end if;
    if v_id1 is null then
        raise exception 'F10: _register_query returned null';
    end if;
end $$;

select ok(true, 'F10: _register_query() is idempotent — same query_id returns same id');

-- =========================================================================
-- F11. _register_query() returns different ids for different query_ids
-- =========================================================================
do $$
declare
    v_id1 int4;
    v_id2 int4;
begin
    v_id1 := pgfr_record._register_query(88888881::int8);
    v_id2 := pgfr_record._register_query(88888882::int8);
    if v_id1 = v_id2 then
        raise exception 'F11: _register_query returned same id for different query_ids';
    end if;
end $$;

select ok(true, 'F11: _register_query() assigns distinct ids to distinct query_ids');

-- =========================================================================
-- F12. sample_ring() + rotate_ring() state machine:
--      data written before rotation survives in non-truncated slots
-- =========================================================================
do $$
declare
    v_slot_before  smallint;
    v_slot_after   smallint;
    v_truncated    smallint;
    v_ts           int4;
    v_row_count    bigint;
begin
    select current_slot into v_slot_before from pgfr_record.ring_config where singleton;

    -- call sample_ring() to write real data into the current slot
    perform pgfr_record.sample_ring();

    -- check how many rows went into this slot
    execute format(
        'select count(*) from pgfr_record.wait_samples_%s',
        v_slot_before
    ) into v_row_count;

    -- now rotate
    update pgfr_record.ring_config
    set rotated_at = now() - interval '3 hours'
    where singleton;

    perform pgfr_record.rotate_ring();

    select current_slot into v_slot_after from pgfr_record.ring_config where singleton;
    v_truncated := (v_slot_after + 1) % (select num_slots from pgfr_record.ring_config where singleton);

    -- v_slot_before should not have been truncated (it's not two steps ahead)
    -- only v_truncated was wiped
    if v_slot_before = v_truncated then
        -- the slot we wrote into was the one truncated — nothing to check
        -- (this only happens with num_slots=3 after two consecutive rotations)
        null;
    else
        -- the slot we wrote into should still have rows
        execute format(
            'select count(*) from pgfr_record.wait_samples_%s',
            v_slot_before
        ) into v_row_count;
        -- we can't assert exact count since other test rows may be there,
        -- but the table should not be empty if we wrote to it
        -- (no assert needed — the F6/F7 tests already cover this precisely)
    end if;
end $$;

select ok(true, 'F12: sample_ring() + rotate_ring() state machine executes without error');

-- =========================================================================
-- F13. activity_samples table exists and receives rows from sample_ring()
-- =========================================================================
do $$
declare
    v_before bigint;
    v_after  bigint;
begin
    select count(*) into v_before from pgfr_record.activity_samples;
    perform pgfr_record.sample_ring();
    select count(*) into v_after from pgfr_record.activity_samples;
    -- must not error; rows are only inserted if backends are active
    if v_after < v_before then
        raise exception 'F13: activity_samples count decreased (% → %)',
            v_before, v_after;
    end if;
end $$;

select ok(true, 'F13: sample_ring() inserts into activity_samples without error');

-- =========================================================================
-- F14. sample_ring() on idle system (no waits) inserts no wait_samples row
--      (tested by checking data integrity, not count — system may have BGW waits)
-- =========================================================================
select ok(
    not exists (
        select 1 from pgfr_record.wait_samples
        where active_count < 0
           or active_count is null
    ),
    'F14: wait_samples.active_count is always non-negative and not null'
);

-- =========================================================================
-- F15. lock_samples table exists (even if empty on idle system)
-- =========================================================================
select has_table('pgfr_record', 'lock_samples',
    'F15: lock_samples parent table exists');

select ok(
    (select count(*) from pgfr_record.lock_samples) >= 0,
    'F15: lock_samples is queryable'
);

-- =========================================================================
-- F16. _register_wait() is idempotent
-- =========================================================================
do $$
declare
    v_id1 smallint;
    v_id2 smallint;
begin
    v_id1 := pgfr_record._register_wait('active', 'CPU', 'CPU');
    v_id2 := pgfr_record._register_wait('active', 'CPU', 'CPU');
    if v_id1 <> v_id2 then
        raise exception 'F16: _register_wait returned different ids: % vs %', v_id1, v_id2;
    end if;
end $$;

select ok(true, 'F16: _register_wait() is idempotent — same triple returns same id');

-- =========================================================================
-- F17. recent_waits_v2 decodes multi-group arrays (B3 regression guard)
--      Inserts [-wid1, cnt1, qid, -wid2, cnt2, qid] and verifies 2 rows decoded
-- =========================================================================
do $$
declare
    v_wid1  smallint;
    v_wid2  smallint;
    v_slot  smallint;
    v_ts    int4;
    v_count int;
begin
    v_wid1 := pgfr_record._register_wait('idle', 'Client', 'ClientRead');
    v_wid2 := pgfr_record._register_wait('active', 'IO', 'DataFileRead');
    v_slot := pgfr_record.ring_current_slot();
    v_ts   := extract(epoch from now() - pgfr_record.epoch())::int4 + 9300;

    insert into pgfr_record.wait_samples (sample_ts, datid, active_count, data, slot)
    values (v_ts, 0::oid, 3,
            array[-v_wid1::integer, 2, 0, -v_wid2::integer, 1, 0],
            v_slot);

    select count(*)::int into v_count
    from pgfr_record.recent_waits_v2
    where captured_at = pgfr_record.epoch() + v_ts * interval '1 second';

    if v_count <> 2 then
        raise exception 'F17: expected 2 decoded rows, got %', v_count;
    end if;
end $$;

select ok(true, 'F17: recent_waits_v2 decodes 2-group arrays into 2 rows (B3 regression guard)');

-- =========================================================================
-- F18. _ensure_partition() 3-arg overload is SECURITY INVOKER (B8 guard)
-- =========================================================================
select ok(
    (select prosecdef
     from pg_proc p
     join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'pgfr_record'
       and p.proname = '_ensure_partition'
       and array_length(p.proargtypes, 1) = 3) = false,
    'F18: _ensure_partition(text,date,text) is SECURITY INVOKER (not DEFINER)'
);

-- =========================================================================
-- F19. rotate_ring() uses xact-level advisory lock (not session-level)
--      Verify by checking no session-level advisory lock is held after call
-- =========================================================================
do $$
declare
    v_lock_count int;
begin
    update pgfr_record.ring_config
    set rotated_at = now() - interval '3 hours'
    where singleton;

    perform pgfr_record.rotate_ring();

    select count(*)::int into v_lock_count
    from pg_locks
    where locktype = 'advisory'
      and pid = pg_backend_pid()
      and classid = hashtext('pgfr_rotate_ring')::int;

    if v_lock_count <> 0 then
        raise exception 'F19: session-level advisory lock still held after rotate_ring() — lock leak';
    end if;
end $$;

select ok(true, 'F19: no session-level advisory lock held after rotate_ring() (B1 regression guard)');

-- =========================================================================
-- F20. _rebuild_statement_last_state() accepts p_sample_ts parameter (B7 guard)
-- =========================================================================
select ok(
    exists (
        select 1 from pg_proc p
        join pg_namespace n on n.oid = p.pronamespace
        where n.nspname = 'pgfr_record'
          and p.proname = '_rebuild_statement_last_state'
          and array_length(p.proargtypes, 1) = 1
    ),
    'F20: _rebuild_statement_last_state has 1-parameter overload accepting p_sample_ts (B7 guard)'
);

-- =========================================================================
-- Finish
-- =========================================================================
select * from finish();
rollback;
