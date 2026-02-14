-- =============================================================================
-- Uninstall pgfr_record reporting functions
-- =============================================================================
-- Removes the reporting schema and all reporting functions/views.
-- Core tables and collection functions in pgfr schema are preserved.
--
-- Run with: psql --single-transaction -f _analyze/uninstall.sql
--
-- To completely remove everything including data:
--   psql --single-transaction -f _record/uninstall.sql
-- =============================================================================

DROP SCHEMA IF EXISTS pgfr_analyze CASCADE;

DO $$
BEGIN
    RAISE NOTICE '';
    RAISE NOTICE '=== Flight Recorder Reporting Uninstalled ===';
    RAISE NOTICE '';
    RAISE NOTICE 'Removed:';
    RAISE NOTICE '  - All reporting functions and views';
    RAISE NOTICE '';
    RAISE NOTICE 'Preserved (in pgfr schema):';
    RAISE NOTICE '  - All core tables and data';
    RAISE NOTICE '  - All core collection functions';
    RAISE NOTICE '  - All scheduled cron jobs';
    RAISE NOTICE '  - Configuration settings';
    RAISE NOTICE '';
    RAISE NOTICE 'To reinstall reporting: psql --single-transaction -f _analyze/install.sql';
    RAISE NOTICE '';
END $$;
