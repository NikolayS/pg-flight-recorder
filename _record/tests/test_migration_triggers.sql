-- =============================================================================
-- pgfr_record pgTAP Tests — Phase 3 Migration: INSTEAD OF INSERT Triggers
-- =============================================================================
-- Tests the INSTEAD OF INSERT triggers created by migrate_phase3.sql.
-- Requires: install.sql applied FIRST, then migrate_phase3.sql applied SECOND.
-- Run via: psql -f tests/test_migration_triggers.sql
--
-- NOTE: This test applies the migration (migrate_phase3.sql) and does NOT roll
-- it back — run against a throwaway database or re-install after.
-- =============================================================================

-- Seed snapshots_v2 (needed for migration pre-flight)
select pgfr_record.snapshot();
select pgfr_record.snapshot();

-- Apply phase 3 migration
\i /tmp/migrate_phase3.sql

begin;
select plan(6);

-- T1: snapshots view is now a UNION ALL view (not a base table)
select ok(
    (select relkind from pg_class c join pg_namespace n on n.oid = c.relnamespace
     where n.nspname = 'pgfr_record' and c.relname = 'snapshots') = 'v',
    'T1: snapshots is a view after migration'
);

-- T2: INSTEAD OF INSERT trigger exists on snapshots view
select ok(
    exists(
        select 1 from pg_trigger t
        join pg_class c on c.oid = t.tgrelid
        join pg_namespace n on n.oid = c.relnamespace
        where n.nspname = 'pgfr_record' and c.relname = 'snapshots'
          and t.tgname = 'snapshots_view_insert'
    ),
    'T2: snapshots_view_insert trigger exists on snapshots view'
);

-- T3: snapshot() works without errors after migration
do $$
begin
    perform pgfr_record.snapshot();
end $$;
select ok(true, 'T3: snapshot() executes without error post-migration');

-- T4: snapshot() routes to snapshots_v2 (row count increases)
select ok(
    (select count(*) from pgfr_record.snapshots_v2) >= 3,
    'T4: snapshots_v2 has >= 3 rows (2 pre-migration + >= 1 post-migration)'
);

-- T5: snapshots view returns UNION ALL of v2 + legacy
select ok(
    (select count(*) from pgfr_record.snapshots)
    = (select count(*) from pgfr_record.snapshots_v2)
      + (select count(*) from pgfr_record.snapshots_legacy),
    'T5: snapshots view count = snapshots_v2 + snapshots_legacy'
);

-- T6: bare INSERT (only captured_at, no pg_version) works via trigger default
do $$
declare v_id integer;
begin
    insert into pgfr_record.snapshots (captured_at)
    values (now())
    returning id into v_id;
    if v_id is null then
        raise exception 'RETURNING id returned null';
    end if;
end $$;
select ok(true, 'T6: bare INSERT INTO snapshots (captured_at) works, RETURNING id non-null');

select * from finish();
rollback;
