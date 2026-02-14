-- Uninstall pgfr_analyze (reporting/analysis functions)
-- Run with: psql --single-transaction -f _analyze/uninstall.sql

DROP SCHEMA IF EXISTS pgfr_analyze CASCADE;
