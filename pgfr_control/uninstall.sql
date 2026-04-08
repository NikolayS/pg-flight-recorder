-- Uninstall pgfr_control (vacuum control functions)
-- Run with: psql --single-transaction -f pgfr_control/uninstall.sql

DROP SCHEMA IF EXISTS pgfr_control CASCADE;
