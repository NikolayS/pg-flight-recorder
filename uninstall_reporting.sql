-- =============================================================================
-- Uninstall pg_flight_recorder reporting functions
-- =============================================================================
-- Removes the reporting schema and all reporting functions/views.
-- Core tables and collection functions in flight_recorder schema are preserved.
--
-- Run with: psql -f uninstall_reporting.sql
--
-- To completely remove everything including data:
--   psql -f uninstall.sql
-- =============================================================================

DROP SCHEMA IF EXISTS flight_recorder_reporting CASCADE;

DO $$
BEGIN
    RAISE NOTICE '';
    RAISE NOTICE '=== Flight Recorder Reporting Uninstalled ===';
    RAISE NOTICE '';
    RAISE NOTICE 'Removed:';
    RAISE NOTICE '  - All reporting functions and views';
    RAISE NOTICE '';
    RAISE NOTICE 'Preserved (in flight_recorder schema):';
    RAISE NOTICE '  - All core tables and data';
    RAISE NOTICE '  - All core collection functions';
    RAISE NOTICE '  - All scheduled cron jobs';
    RAISE NOTICE '  - Configuration settings';
    RAISE NOTICE '';
    RAISE NOTICE 'To reinstall reporting: psql -f reporting.sql';
    RAISE NOTICE '';
END $$;
