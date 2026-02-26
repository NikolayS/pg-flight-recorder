-- baseline_measure.sql — §9.2 Baseline measurements for pg-flight-recorder
-- Exact queries from SPEC.md §9.2
-- Run against: pgfr_bench17 on port 5433 (PG17)
-- Output: CSV (use psql --csv -f baseline_measure.sql)

-- ── §9.2 Query 1: Actual row counts and bytes per row ────────────────────────
\echo '--- Section: row_counts_and_sizes ---'

SELECT
    'row_counts_and_sizes'           AS measurement,
    schemaname,
    relname,
    n_live_tup,
    n_dead_tup,
    pg_size_pretty(pg_relation_size(relid))        AS heap_size,
    pg_size_pretty(pg_total_relation_size(relid))  AS total_size,
    pg_relation_size(relid) / NULLIF(n_live_tup, 0) AS bytes_per_row
FROM pg_stat_user_tables
WHERE schemaname = 'pgfr_record'
ORDER BY pg_total_relation_size(relid) DESC;

-- ── §9.2 Query 2: Collection latency per section ────────────────────────────
\echo '--- Section: collection_latency ---'

SELECT
    'collection_latency'             AS measurement,
    section_name,
    round(avg(duration_ms)::numeric, 2)   AS avg_ms,
    max(duration_ms)                       AS max_ms,
    count(*)                               AS samples
FROM pgfr_record.collection_stats
WHERE captured_at > now() - INTERVAL '1 hour'
GROUP BY section_name
ORDER BY avg_ms DESC;

-- ── §9.2 Query 3: Rows inserted per hour ────────────────────────────────────
\echo '--- Section: rows_inserted_per_hour ---'

SELECT
    'rows_inserted_per_hour'          AS measurement,
    date_trunc('hour', s.captured_at) AS hour,
    count(*)                          AS rows_inserted
FROM pgfr_record.statement_snapshots ss
JOIN pgfr_record.snapshots s ON s.id = ss.snapshot_id
GROUP BY 1, 2
ORDER BY 2;

-- ── Additional: actual pg_stat_statements utilization ───────────────────────
\echo '--- Section: pgss_utilization ---'

SELECT
    'pgss_utilization'               AS measurement,
    current_statements,
    max_statements,
    utilization_pct,
    dealloc_count,
    status
FROM pgfr_record._check_statements_health();

-- ── Additional: snapshot timing summary ─────────────────────────────────────
\echo '--- Section: snapshot_timing_summary ---'

SELECT
    'snapshot_timing_summary'         AS measurement,
    count(*)                          AS total_snapshots,
    min(captured_at)                  AS first_snapshot,
    max(captured_at)                  AS last_snapshot,
    EXTRACT(EPOCH FROM (max(captured_at) - min(captured_at))) / 3600 AS hours_of_data
FROM pgfr_record.snapshots;

-- ── Additional: total collection overhead ───────────────────────────────────
\echo '--- Section: total_collection_overhead ---'

SELECT
    'total_collection_overhead'       AS measurement,
    collection_type,
    round(avg(duration_ms)::numeric, 2) AS avg_ms,
    max(duration_ms)                     AS max_ms,
    min(duration_ms)                     AS min_ms,
    count(*)                             AS runs,
    sum(CASE WHEN success THEN 1 ELSE 0 END) AS successes,
    sum(CASE WHEN NOT success THEN 1 ELSE 0 END) AS failures
FROM pgfr_record.collection_stats
GROUP BY collection_type
ORDER BY avg_ms DESC;

-- ── Additional: statement_snapshots bytes per row ────────────────────────────
\echo '--- Section: statement_snapshot_bytes ---'

SELECT
    'statement_snapshot_bytes'       AS measurement,
    count(*)                          AS row_count,
    pg_size_pretty(pg_total_relation_size('pgfr_record.statement_snapshots'))
                                      AS total_size,
    CASE WHEN count(*) > 0 THEN
        pg_total_relation_size('pgfr_record.statement_snapshots') / count(*)
    ELSE NULL END                     AS bytes_per_row_estimated
FROM pgfr_record.statement_snapshots;

-- ── Additional: pgbench workload stats ───────────────────────────────────────
\echo '--- Section: pgbench_stats ---'

SELECT
    'pgbench_stats'                   AS measurement,
    s.query_preview,
    s.calls,
    round(s.total_exec_time::numeric, 2) AS total_exec_time_ms,
    round(s.mean_exec_time::numeric, 4)  AS mean_exec_time_ms,
    s.rows
FROM (
    SELECT
        left(p.query, 80)    AS query_preview,
        p.calls,
        p.total_exec_time,
        p.mean_exec_time,
        p.rows
    FROM pg_stat_statements p
    WHERE p.dbid = (SELECT oid FROM pg_database WHERE datname = current_database())
    ORDER BY p.calls DESC
    LIMIT 10
) s;
