-- bloat_demo_long_tx.sql
-- Part 2 of the bloat demo: run UPDATE churn while a background long-running
-- transaction holds the oldest xmin, preventing VACUUM from reclaiming dead tuples.
--
-- Run AFTER bloat_demo_old_schema.sql has created and pre-populated the tables.
--
-- How to run (two terminal windows):
--
--   Terminal 1 — open the long-running tx and keep it idle:
--     psql -U postgres -d pgfr_bench -c "
--       begin;
--       select 'I am the horizon pinning long tx', pg_backend_pid(), txid_current();
--       -- DO NOT commit — leave this running
--     "
--
--   Terminal 2 — run this script (churn + measure):
--     psql -U postgres -d pgfr_bench -f bloat_demo_long_tx.sql
--
-- Or use the automated wrapper: scripts/run_bloat_demo.sh

\qecho ''
\qecho '=== Long-running tx bloat demo ==='
\qecho 'Assumption: a separate session holds an open tx (horizon pinned).'
\qecho 'Run scripts/run_bloat_demo.sh for the automated version.'
\qecho ''

-- Show current oldest xmin (horizon)
select
    pid,
    backend_xmin,
    now() - xact_start as tx_age,
    left(query, 60) as query_preview
from pg_stat_activity
where backend_xmin is not null
order by backend_xmin
limit 5;

-- Snapshot size before churn
\qecho ''
\qecho '--- Size BEFORE churn (long tx active) ---'
select
    relname                                      as table_name,
    n_live_tup                                   as live_rows,
    n_dead_tup                                   as dead_rows,
    pg_size_pretty(pg_relation_size(relid))      as heap_size
from pg_stat_user_tables
where schemaname = 'pgfr_bloat_demo'
order by pg_total_relation_size(relid) desc;

-- Simulate 200 UPDATE ticks (autovacuum cannot reclaim — horizon pinned)
do $$
declare
    v_slot  integer;
    v_tick  integer;
begin
    for v_tick in 1..200 loop
        v_slot := v_tick % 120;

        update pgfr_bloat_demo.samples_ring
        set captured_at = now(), epoch_secs = extract(epoch from now())
        where slot_id = v_slot;

        -- Full slot reset (all 100 rows go dead)
        update pgfr_bloat_demo.wait_samples_ring
        set wait_event_type = null, wait_event = null, state = null, count = null
        where slot_id = v_slot;

        -- Re-write 20 "active" rows
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

-- Attempt vacuum (will be blocked from reclaiming by open tx)
vacuum pgfr_bloat_demo.wait_samples_ring;

\qecho ''
\qecho '--- Size AFTER 200 ticks + VACUUM (horizon pinned by long tx) ---'
select
    relname                                      as table_name,
    n_live_tup                                   as live_rows,
    n_dead_tup                                   as dead_rows,
    pg_size_pretty(pg_relation_size(relid))      as heap_size,
    case when n_live_tup > 0
         then pg_relation_size(relid) / n_live_tup
    end                                          as bytes_per_live_row
from pg_stat_user_tables
where schemaname = 'pgfr_bloat_demo'
order by pg_total_relation_size(relid) desc;

\qecho ''
\qecho '--- Dead tuple detail from pg_stat_user_tables ---'
select
    relname,
    n_live_tup,
    n_dead_tup,
    round(100.0 * n_dead_tup / nullif(n_live_tup + n_dead_tup, 0), 1) as dead_pct,
    last_vacuum,
    last_autovacuum
from pg_stat_user_tables
where schemaname = 'pgfr_bloat_demo';

\qecho ''
\qecho '--- pgstattuple bloat estimate (requires pgstattuple extension) ---'
-- install with: CREATE EXTENSION pgstattuple;
-- select * from pgstattuple('pgfr_bloat_demo.wait_samples_ring');
