-- =============================================================================
-- Uninstall pgfr_record (DESTRUCTIVE)
-- =============================================================================
-- WARNING: This removes ALL data including historical snapshots!
-- Use this only when you want to completely remove pgfr.
--
-- To remove only reporting functions: psql --single-transaction -f _analyze/uninstall.sql
--
-- Run with: psql --single-transaction -f _record/uninstall.sql
-- =============================================================================

-- Remove all cron jobs and clean up job history
DO $$
DECLARE
    v_jobids BIGINT[];
    v_deleted_count INTEGER;
BEGIN
    -- Collect job IDs before unscheduling
    SELECT array_agg(jobid) INTO v_jobids
    FROM cron.job
    WHERE jobname IN ('pgfr_snapshot', 'pgfr_sample', 'pgfr_flush', 'pgfr_archive', 'pgfr_cleanup');

    -- Unschedule jobs
    PERFORM cron.unschedule('pgfr_snapshot')
    WHERE EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'pgfr_snapshot');

    PERFORM cron.unschedule('pgfr_sample')
    WHERE EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'pgfr_sample');

    PERFORM cron.unschedule('pgfr_flush')
    WHERE EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'pgfr_flush');

    PERFORM cron.unschedule('pgfr_archive')
    WHERE EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'pgfr_archive');

    PERFORM cron.unschedule('pgfr_cleanup')
    WHERE EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'pgfr_cleanup');

    -- Clean up job run history
    IF v_jobids IS NOT NULL THEN
        DELETE FROM cron.job_run_details WHERE jobid = ANY(v_jobids);
        GET DIAGNOSTICS v_deleted_count = ROW_COUNT;
        IF v_deleted_count > 0 THEN
            RAISE NOTICE 'Cleaned up % job run history records', v_deleted_count;
        END IF;
    END IF;
EXCEPTION
    WHEN undefined_table THEN NULL;  -- cron schema doesn't exist
    WHEN undefined_function THEN NULL;  -- cron.unschedule doesn't exist
END;
$$;

-- Drop schemas and all objects
DROP SCHEMA IF EXISTS pgfr_analyze CASCADE;
DROP SCHEMA IF EXISTS pgfr CASCADE;

DO $$
BEGIN
    RAISE NOTICE '';
    RAISE NOTICE 'Flight Recorder uninstalled successfully.';
    RAISE NOTICE '';
    RAISE NOTICE 'Removed:';
    RAISE NOTICE '  - All flight recorder tables and data';
    RAISE NOTICE '  - All flight recorder functions and views';
    RAISE NOTICE '  - All reporting functions and views';
    RAISE NOTICE '  - All scheduled cron jobs (snapshot, sample, flush, archive, cleanup)';
    RAISE NOTICE '  - All cron job execution history';
    RAISE NOTICE '';
END;
$$;
