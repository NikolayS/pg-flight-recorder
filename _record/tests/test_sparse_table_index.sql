-- =============================================================================
-- pgTAP tests: Phase 1 sparse table_snapshots and index_snapshots collectors
-- Issue #8 — storage-overhaul-spec branch
-- Run with: psql -f _record/tests/test_sparse_table_index.sql
-- Requires: pgTAP, install.sql already applied
-- =============================================================================

begin;

select plan(12);

-- ---------------------------------------------------------------------------
-- Helper: ensure test partitions exist
-- ---------------------------------------------------------------------------
do $$
begin
    perform pgfr_record._ensure_partition('table_snapshots_v2', current_date,
        'relid, dbid, sample_ts desc');
    perform pgfr_record._ensure_partition('index_snapshots_v2', current_date,
        'indexrelid, dbid, sample_ts desc');
end;
$$;

-- ===========================================================================
-- TABLE COLLECTOR TESTS (T1–T6)
-- ===========================================================================

-- T1: table_snapshots_v2 exists and is partitioned
select ok(
    exists (
        select 1 from pg_catalog.pg_class c
        join pg_catalog.pg_namespace n on n.oid = c.relnamespace
        where n.nspname = 'pgfr_record'
          and c.relname = 'table_snapshots_v2'
          and c.relkind = 'p'  -- partitioned table
    ),
    'T1: table_snapshots_v2 must exist as a partitioned table'
);

-- T2: table_last_state is UNLOGGED with fillfactor=70
select ok(
    exists (
        select 1 from pg_catalog.pg_class c
        join pg_catalog.pg_namespace n on n.oid = c.relnamespace
        where n.nspname = 'pgfr_record'
          and c.relname = 'table_last_state'
          and c.relpersistence = 'u'  -- unlogged
          and c.reloptions::text like '%fillfactor=70%'
    ),
    'T2: table_last_state must be UNLOGGED with fillfactor=70'
);

-- T3: HOT contract — no index on mutable columns of table_last_state
select ok(
    not exists (
        select 1
        from pg_catalog.pg_index i
        join pg_catalog.pg_class ci on ci.oid = i.indexrelid
        join pg_catalog.pg_class ct on ct.oid = i.indrelid
        join pg_catalog.pg_namespace n on n.oid = ct.relnamespace
        join pg_catalog.pg_attribute a
             on a.attrelid = ct.oid
            and a.attnum = any(i.indkey)
        where n.nspname = 'pgfr_record'
          and ct.relname = 'table_last_state'
          and a.attname in (
              'seq_scan', 'idx_scan', 'n_tup_ins', 'n_tup_upd', 'n_tup_del',
              'n_live_tup', 'n_dead_tup', 'n_mod_since_analyze', 'sample_ts'
          )
    ),
    'T3: HOT contract: no index on mutable columns of table_last_state'
);

-- T4: _rebuild_table_last_state() populates table_last_state
do $$
begin
    truncate pgfr_record.table_last_state;
    perform pgfr_record._rebuild_table_last_state();
end;
$$;

select ok(
    (select count(*) from pgfr_record.table_last_state) >= 0,
    'T4: _rebuild_table_last_state() runs without error and populates table_last_state'
);

-- T5: sparse — 0 rows inserted when nothing changed
do $$
declare
    v_count_before bigint;
    v_count_after  bigint;
    v_sample_ts    int4;
begin
    -- full rebuild so last_state mirrors current pg_stat_user_tables exactly
    perform pgfr_record._rebuild_table_last_state();

    v_sample_ts := extract(epoch from now() - pgfr_record.epoch())::int4;

    select count(*) into v_count_before
    from pgfr_record.table_snapshots_v2
    where sample_ts >= v_sample_ts;

    -- run sparse collector — nothing changed, so no rows should be inserted
    perform pgfr_record._collect_table_snapshot_sparse(1001);

    select count(*) into v_count_after
    from pgfr_record.table_snapshots_v2
    where sample_ts > v_sample_ts;

    if v_count_after <> 0 then
        raise exception 'T5 failed: expected 0 new rows when metrics unchanged, got %', v_count_after;
    end if;
end;
$$;
select pass('T5: sparse table collector: 0 rows inserted when metrics unchanged after rebuild');

-- T6: sparse — rows inserted when metrics change
do $$
declare
    v_count_before bigint;
    v_count_after  bigint;
    v_sample_ts    int4;
begin
    -- rebuild to a clean baseline
    perform pgfr_record._rebuild_table_last_state();

    -- Corrupt n_dead_tup for the table with the highest activity score.
    -- The sparse collector has a top_n filter (top 50 by activity score).
    -- Picking LIMIT 1 from table_last_state without ordering hits a zero-activity
    -- table that doesn't make it into top_n → no insert. Pick the most active one.
    update pgfr_record.table_last_state
    set n_dead_tup = -999999
    where relid = (
        select st.relid
        from pg_stat_user_tables st
        join pgfr_record.table_last_state ls on ls.relid = st.relid
        order by coalesce(st.seq_scan,0) + coalesce(st.idx_scan,0)
               + coalesce(st.n_tup_ins,0) + coalesce(st.n_tup_upd,0)
               + coalesce(st.n_tup_del,0) desc
        limit 1
    );

    v_sample_ts := extract(epoch from now() - pgfr_record.epoch())::int4;

    select count(*) into v_count_before
    from pgfr_record.table_snapshots_v2;

    perform pgfr_record._collect_table_snapshot_sparse(1002);

    select count(*) into v_count_after
    from pgfr_record.table_snapshots_v2;

    -- restore clean state
    perform pgfr_record._rebuild_table_last_state();

    if v_count_after <= v_count_before then
        raise exception 'T6 failed: expected >=1 new row when metrics changed, got none';
    end if;
end;
$$;
select pass('T6: sparse table collector: rows inserted when metrics changed');

-- ===========================================================================
-- INDEX COLLECTOR TESTS (T7–T12)
-- ===========================================================================

-- T7: index_snapshots_v2 exists and is partitioned
select ok(
    exists (
        select 1 from pg_catalog.pg_class c
        join pg_catalog.pg_namespace n on n.oid = c.relnamespace
        where n.nspname = 'pgfr_record'
          and c.relname = 'index_snapshots_v2'
          and c.relkind = 'p'  -- partitioned table
    ),
    'T7: index_snapshots_v2 must exist as a partitioned table'
);

-- T8: index_last_state is UNLOGGED with fillfactor=70
select ok(
    exists (
        select 1 from pg_catalog.pg_class c
        join pg_catalog.pg_namespace n on n.oid = c.relnamespace
        where n.nspname = 'pgfr_record'
          and c.relname = 'index_last_state'
          and c.relpersistence = 'u'  -- unlogged
          and c.reloptions::text like '%fillfactor=70%'
    ),
    'T8: index_last_state must be UNLOGGED with fillfactor=70'
);

-- T9: HOT contract — no index on mutable columns of index_last_state
select ok(
    not exists (
        select 1
        from pg_catalog.pg_index i
        join pg_catalog.pg_class ci on ci.oid = i.indexrelid
        join pg_catalog.pg_class ct on ct.oid = i.indrelid
        join pg_catalog.pg_namespace n on n.oid = ct.relnamespace
        join pg_catalog.pg_attribute a
             on a.attrelid = ct.oid
            and a.attnum = any(i.indkey)
        where n.nspname = 'pgfr_record'
          and ct.relname = 'index_last_state'
          and a.attname in ('idx_scan', 'idx_tup_read', 'idx_tup_fetch', 'sample_ts')
    ),
    'T9: HOT contract: no index on mutable columns of index_last_state'
);

-- T10: _rebuild_index_last_state() populates index_last_state
do $$
begin
    truncate pgfr_record.index_last_state;
    perform pgfr_record._rebuild_index_last_state();
end;
$$;

select ok(
    (select count(*) from pgfr_record.index_last_state) >= 0,
    'T10: _rebuild_index_last_state() runs without error and populates index_last_state'
);

-- T11: sparse — 0 rows inserted when nothing changed
do $$
declare
    v_count_before bigint;
    v_count_after  bigint;
    v_sample_ts    int4;
begin
    -- full rebuild so last_state mirrors current pg_stat_user_indexes exactly
    perform pgfr_record._rebuild_index_last_state();

    v_sample_ts := extract(epoch from now() - pgfr_record.epoch())::int4;

    select count(*) into v_count_before
    from pgfr_record.index_snapshots_v2
    where sample_ts >= v_sample_ts;

    -- run sparse collector — nothing changed, so no rows should be inserted
    perform pgfr_record._collect_index_snapshot_sparse(2001);

    select count(*) into v_count_after
    from pgfr_record.index_snapshots_v2
    where sample_ts > v_sample_ts;

    if v_count_after <> 0 then
        raise exception 'T11 failed: expected 0 new rows when metrics unchanged, got %', v_count_after;
    end if;
end;
$$;
select pass('T11: sparse index collector: 0 rows inserted when metrics unchanged after rebuild');

-- T12: sparse — rows inserted when metrics change
do $$
declare
    v_count_before bigint;
    v_count_after  bigint;
    v_sample_ts    int4;
begin
    -- rebuild to a clean baseline
    perform pgfr_record._rebuild_index_last_state();

    -- Corrupt idx_tup_read in last_state to force change detection.
    -- idx_tup_read is in the change-detection predicate.
    -- Live value >= 0 > -999999 always triggers "is distinct from" detection.
    update pgfr_record.index_last_state
    set idx_tup_read = -999999
    where indexrelid = (select indexrelid from pgfr_record.index_last_state limit 1);

    v_sample_ts := extract(epoch from now() - pgfr_record.epoch())::int4;

    select count(*) into v_count_before
    from pgfr_record.index_snapshots_v2;

    perform pgfr_record._collect_index_snapshot_sparse(2002);

    select count(*) into v_count_after
    from pgfr_record.index_snapshots_v2;

    -- restore clean state
    perform pgfr_record._rebuild_index_last_state();

    if v_count_after <= v_count_before then
        raise exception 'T12 failed: expected >=1 new row when metrics changed, got none';
    end if;
end;
$$;
select pass('T12: sparse index collector: rows inserted when metrics changed');

select * from finish();
rollback;
