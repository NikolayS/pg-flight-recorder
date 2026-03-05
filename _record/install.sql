-- pg-flight-recorder: _record module install script
--
-- Orchestrates load order. Each sql/ file is independently reviewable.
-- Run as a superuser in the target database with pg_cron installed.
--
-- Files:
--   01_schema.sql            extension check, schema, search_path
--   02_tables_legacy.sql     legacy heap tables (snapshots, *_ring, aggregates, archives)
--   03_functions_util.sql    helpers: _pg_version, epoch, _get_config, circuit breakers
--   04a_functions_sample.sql wait/lock/activity ring samplers (old UPDATE pattern)
--   04b_functions_snapshot.sql snapshot(), _collect_* collectors
--   05_functions_ops.sql     cleanup(), enable/disable, set_mode, profiles
--   06_partition_infra.sql   _ensure_partition, _partition_inventory, truncate/drop GC
--   07_sparse_collectors.sql sparse PGSS/table/index collectors (v2 INSERT pattern)
--   08_ring_buffer_v2.sql    ring buffer v2 tables, sample_ring, rotate_ring, flush, archive
--   09_phase3_snapshots_v2.sql snapshots_v2 partitioned tables + dual-write trigger

\i sql/01_schema.sql
\i sql/02_tables_legacy.sql
\i sql/03_functions_util.sql
\i sql/04a_functions_sample.sql
\i sql/04b_functions_snapshot.sql
\i sql/05_functions_ops.sql
\i sql/06_partition_infra.sql
\i sql/07_sparse_collectors.sql
\i sql/08_ring_buffer_v2.sql
\i sql/09_phase3_snapshots_v2.sql
