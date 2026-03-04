-- =============================================================================
-- pgfr_record pgTAP Tests — Phase 1 Migration (Issue #10)
-- =============================================================================
-- Tests: migrate_to_v2() function existence, idempotency, and correctness
-- Requires: install.sql loaded; v2 stub tables created by the test setup below
-- =============================================================================

begin;
select plan(10);

-- =============================================================================
-- Setup: create minimal v2 stub tables so migrate_to_v2() can find them.
-- In production these are created by the new install.sql.  Here we create them
-- as empty stubs so the migration logic can be exercised in isolation without
-- requiring the full Phase 1 implementation to be merged.
-- =============================================================================
do $$
begin
    -- statement_snapshots_v2 stub
    if not exists (
        select 1 from pg_catalog.pg_class c
        join pg_catalog.pg_namespace n on n.oid = c.relnamespace
        where n.nspname = 'pgfr_record' and c.relname = 'statement_snapshots_v2'
    ) then
        create table pgfr_record.statement_snapshots_v2 (
            snapshot_id bigint,
            queryid     bigint
        );
    end if;

    -- table_snapshots_v2 stub
    if not exists (
        select 1 from pg_catalog.pg_class c
        join pg_catalog.pg_namespace n on n.oid = c.relnamespace
        where n.nspname = 'pgfr_record' and c.relname = 'table_snapshots_v2'
    ) then
        create table pgfr_record.table_snapshots_v2 (
            snapshot_id bigint,
            relid       oid
        );
    end if;

    -- index_snapshots_v2 stub
    if not exists (
        select 1 from pg_catalog.pg_class c
        join pg_catalog.pg_namespace n on n.oid = c.relnamespace
        where n.nspname = 'pgfr_record' and c.relname = 'index_snapshots_v2'
    ) then
        create table pgfr_record.index_snapshots_v2 (
            snapshot_id bigint,
            indexrelid  oid
        );
    end if;
end;
$$;

-- =============================================================================
-- Test 1: migrate_to_v2() function exists
-- =============================================================================
select has_function(
    'pgfr_record',
    'migrate_to_v2',
    'Function pgfr_record.migrate_to_v2() should exist'
);

-- =============================================================================
-- Test 2: function has a COMMENT (documentation contract)
-- =============================================================================
select ok(
    (
        select obj_description(
            'pgfr_record.migrate_to_v2'::regproc,
            'pg_proc'
        ) is not null
    ),
    'pgfr_record.migrate_to_v2() should have a COMMENT'
);

-- =============================================================================
-- Test 3: migrate_to_v2() runs without error (first call)
-- =============================================================================
select lives_ok(
    $$select pgfr_record.migrate_to_v2()$$,
    'migrate_to_v2() should execute without error on first call'
);

-- =============================================================================
-- Test 4: after migration, statement_snapshots_legacy table exists
-- =============================================================================
select has_table(
    'pgfr_record',
    'statement_snapshots_legacy',
    'Table pgfr_record.statement_snapshots_legacy should exist after migration'
);

-- =============================================================================
-- Test 5: after migration, original statement_snapshots table is GONE (renamed)
-- The name now belongs to a view, not a plain table.
-- =============================================================================
select ok(
    not exists (
        select 1
        from pg_catalog.pg_class c
        join pg_catalog.pg_namespace n on n.oid = c.relnamespace
        where n.nspname = 'pgfr_record'
          and c.relname  = 'statement_snapshots'
          and c.relkind  = 'r'  -- plain heap table
    ),
    'pgfr_record.statement_snapshots should no longer be a plain table after migration'
);

-- =============================================================================
-- Test 6: after migration, statement_snapshots VIEW exists
-- =============================================================================
select has_view(
    'pgfr_record',
    'statement_snapshots',
    'View pgfr_record.statement_snapshots should exist after migration (backwards compat)'
);

-- =============================================================================
-- Test 7: the view reads from _legacy (smoke-test: query returns without error)
-- =============================================================================
select lives_ok(
    $$select count(*) from pgfr_record.statement_snapshots$$,
    'SELECT from pgfr_record.statement_snapshots view should succeed (backwards compat)'
);

-- =============================================================================
-- Test 8: idempotency — second call runs without error
-- =============================================================================
select lives_ok(
    $$select pgfr_record.migrate_to_v2()$$,
    'migrate_to_v2() should be idempotent (second call must not raise an error)'
);

-- =============================================================================
-- Test 9: idempotency — statement_snapshots_legacy still exists after second call
-- =============================================================================
select has_table(
    'pgfr_record',
    'statement_snapshots_legacy',
    'statement_snapshots_legacy should still exist after second migrate_to_v2() call'
);

-- =============================================================================
-- Test 10: migrate_to_v2() raises ERROR when v2 tables are missing
-- =============================================================================
do $$
begin
    -- temporarily drop the v2 stubs to simulate "install.sql not run" scenario
    drop table if exists pgfr_record.statement_snapshots_v2 cascade;
    drop table if exists pgfr_record.table_snapshots_v2 cascade;
    drop table if exists pgfr_record.index_snapshots_v2 cascade;
end;
$$;

select throws_ok(
    $$select pgfr_record.migrate_to_v2()$$,
    'P0001',
    NULL,
    'migrate_to_v2() should raise an error when v2 tables do not exist'
);

select * from finish();
rollback;
