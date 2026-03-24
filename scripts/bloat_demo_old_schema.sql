-- bloat_demo_old_schema.sql
-- Demonstrates UPDATE-pattern bloat on the old ring schema under a long-running
-- background transaction. Run as two sessions:
--
--   Session A (blocker):  psql ... -f bloat_demo_old_schema.sql
--   Session B (monitor):  psql ... -f bloat_monitor.sql   (watch -n2)
--
-- Or use the shell wrapper: scripts/run_bloat_demo.sh

-- ── Schema setup ─────────────────────────────────────────────────────────────

drop schema if exists pgfr_bloat_demo cascade;
create schema pgfr_bloat_demo;

-- Old-style ring tables (UNLOGGED, fillfactor=90, UPDATE pattern)
create unlogged table pgfr_bloat_demo.samples_ring (
    slot_id      integer primary key check (slot_id >= 0 and slot_id < 120),
    captured_at  timestamptz not null default now(),
    epoch_secs   bigint not null default 0
) with (fillfactor = 70);

create unlogged table pgfr_bloat_demo.wait_samples_ring (
    slot_id          integer references pgfr_bloat_demo.samples_ring(slot_id) on delete cascade,
    row_num          integer not null check (row_num >= 0 and row_num < 100),
    wait_event_type  text,
    wait_event       text,
    state            text,
    count            integer,
    primary key (slot_id, row_num)
) with (fillfactor = 90);

-- Pre-populate (120 slots × 100 rows = 12,000 rows)
insert into pgfr_bloat_demo.samples_ring (slot_id, captured_at, epoch_secs)
select g, now(), 0
from generate_series(0, 119) as g;

insert into pgfr_bloat_demo.wait_samples_ring (slot_id, row_num)
select s, r
from generate_series(0, 119) as s
cross join generate_series(0, 99) as r;

-- ── Baseline measurement ──────────────────────────────────────────────────────

\qecho ''
\qecho '=== BASELINE (before churn) ==='
select
    relname                                      as table_name,
    n_live_tup                                   as live_rows,
    n_dead_tup                                   as dead_rows,
    pg_size_pretty(pg_relation_size(relid))      as heap_size,
    pg_size_pretty(pg_total_relation_size(relid)) as total_size
from pg_stat_user_tables
where schemaname = 'pgfr_bloat_demo'
order by pg_total_relation_size(relid) desc;

-- ── Simulate 60 UPDATE ticks WITHOUT long tx (vacuum can run freely) ─────────

\qecho ''
\qecho '=== Simulating 60 ticks, no long-running tx (vacuum free to run) ==='

do $$
declare
    v_slot   integer;
    v_tick   integer;
begin
    for v_tick in 1..60 loop
        v_slot := v_tick % 120;

        -- Mimic sample(): reset the slot, then UPDATE individual rows
        update pgfr_bloat_demo.samples_ring
        set captured_at = now(), epoch_secs = extract(epoch from now())
        where slot_id = v_slot;

        update pgfr_bloat_demo.wait_samples_ring
        set wait_event_type = null, wait_event = null, state = null, count = null
        where slot_id = v_slot;

        -- Write 20 "active" wait rows per tick
        update pgfr_bloat_demo.wait_samples_ring
        set
            wait_event_type = (array['Lock','LWLock','IO','Client'])[1 + (row_num % 4)],
            wait_event      = 'Event' || row_num::text,
            state           = 'active',
            count           = 1 + (random() * 10)::int
        where slot_id = v_slot and row_num < 20;
    end loop;
end;
$$;

-- Force VACUUM ANALYZE to reclaim dead tuples
vacuum analyze pgfr_bloat_demo.wait_samples_ring;

\qecho '--- After 60 ticks + VACUUM (baseline bloat with free autovacuum) ---'
select
    relname                                      as table_name,
    n_live_tup                                   as live_rows,
    n_dead_tup                                   as dead_rows,
    pg_size_pretty(pg_relation_size(relid))      as heap_size,
    round(
        100.0 * pg_relation_size(relid)
        / nullif(pg_total_relation_size(relid), 0), 1
    )                                            as heap_pct
from pg_stat_user_tables
where schemaname = 'pgfr_bloat_demo'
order by pg_total_relation_size(relid) desc;
