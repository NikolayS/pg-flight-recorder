-- =============================================================================
-- pgfr_record pgTAP Tests — Phase 3 Migration: Config Key Deprecation
-- =============================================================================
-- Tests: migrate_config_keys(), _resolve_config_key(), _get_config() alias resolution
-- Does NOT require phase 3 migration to be applied (pure function tests).
-- =============================================================================

begin;
select plan(8);

-- =============================================================================
-- T1-T3: _resolve_config_key()
-- =============================================================================

select is(
    pgfr_record._resolve_config_key('retention_samples_days'),
    'retention_archive_days',
    'T1: retention_samples_days resolves to retention_archive_days'
);

select is(
    pgfr_record._resolve_config_key('aggregate_retention_days'),
    'retention_archive_days',
    'T2: aggregate_retention_days resolves to retention_archive_days'
);

select is(
    pgfr_record._resolve_config_key('retention_archive_days'),
    'retention_archive_days',
    'T3: canonical key resolves to itself'
);

-- =============================================================================
-- T4: _get_config() canonical → alias fallback
--     When caller requests canonical key but only old key is in config table,
--     _get_config() should still return the value via _alias_keys_for().
-- =============================================================================

-- Seed only old key; ensure canonical is absent
insert into pgfr_record.config (key, value)
values ('retention_samples_days', '42')
on conflict (key) do update set value = '42';

delete from pgfr_record.config where key = 'retention_archive_days';

select is(
    pgfr_record._get_config('retention_archive_days', '7'),
    '42',
    'T4: _get_config(canonical) returns value stored under deprecated alias key'
);

-- Restore
delete from pgfr_record.config where key = 'retention_samples_days';
insert into pgfr_record.config (key, value)
values ('retention_archive_days', '7')
on conflict (key) do update set value = '7';

-- =============================================================================
-- T5-T8: migrate_config_keys()
-- =============================================================================

-- Scenario A: old key present, canonical exists → old key deleted
insert into pgfr_record.config (key, value) values ('aggregate_retention_days', '5')
on conflict (key) do update set value = '5';

select ok(
    exists(
        select 1 from pgfr_record.migrate_config_keys()
        where old_key = 'aggregate_retention_days' and action = 'deleted (canonical exists)'
    ),
    'T5: migrate_config_keys() deletes old key when canonical exists'
);

select ok(
    not exists(select 1 from pgfr_record.config where key = 'aggregate_retention_days'),
    'T6: aggregate_retention_days removed from config after migration'
);

-- Scenario B: old key only, no canonical → renamed
delete from pgfr_record.config where key = 'retention_archive_days';
insert into pgfr_record.config (key, value) values ('retention_samples_days', '21')
on conflict (key) do update set value = '21';

select ok(
    exists(
        select 1 from pgfr_record.migrate_config_keys()
        where old_key = 'retention_samples_days' and action = 'renamed to canonical'
    ),
    'T7: migrate_config_keys() renames old key to canonical when canonical absent'
);

select is(
    (select value from pgfr_record.config where key = 'retention_archive_days'),
    '21',
    'T8: renamed key preserves original value'
);

select * from finish();
rollback;
