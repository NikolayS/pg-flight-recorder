-- =============================================================================
-- pgfr_analyze pgTAP Tests - v2 Partitioned Table Reader Functions (Issue #11)
-- =============================================================================
-- Tests: v2_time_range, statement_activity_v2, table_activity_v2,
--        index_activity_v2
-- Test count: 14
-- =============================================================================

begin;
select plan(14);

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

select * from finish();
rollback;
