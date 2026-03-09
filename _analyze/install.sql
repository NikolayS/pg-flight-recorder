-- pg-flight-recorder: _analyze module install script
--
-- Requires _record module installed first.
-- Uses absolute paths (/analyze_sql/) — safe to run from any working directory.
--
-- Files:
--   01_core_metrics.sql           schema, modification_rate, hot_update_ratio,
--                                 anomaly_report, summary_report, compare
--   02_ring_readers.sql           recent_waits_current, recent_activity_current,
--                                 recent_locks_current, wait_summary, statement_compare
--   03_activity_storms_regressions.sql  activity_at, detect_query_storms,
--                                 _diagnose_regression_causes, detect_regressions
--   04_reports.sql                performance_report, check_alerts, report (overloads)
--   05_capacity.sql               preflight_check, quarterly_review,
--                                 capacity_summary, capacity_report
--   06_table_analysis.sql         table_compare, table_hotspots
--   07_index_analysis.sql         unused_indexes, index_efficiency
--   08_config.sql                 config_changes, config_at, config_health_check,
--                                 db_role_config_* functions
--   09_incident_analysis.sql      what_happened_at, incident_timeline, blast_radius
--   10_v2_readers.sql             v2_time_range, statement/table/index_activity_v2,
--                                 ring v2 reader rewrites

\i /analyze_sql/01_core_metrics.sql
\i /analyze_sql/02_ring_readers.sql
\i /analyze_sql/03_activity_storms_regressions.sql
\i /analyze_sql/04_reports.sql
\i /analyze_sql/05_capacity.sql
\i /analyze_sql/06_table_analysis.sql
\i /analyze_sql/07_index_analysis.sql
\i /analyze_sql/08_config.sql
\i /analyze_sql/09_incident_analysis.sql
\i /analyze_sql/10_v2_readers.sql
