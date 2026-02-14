-- Uninstall pgfr_control (vacuum control functions)
-- Run with: psql --single-transaction -f _control/uninstall.sql

DROP SCHEMA IF EXISTS pgfr_control CASCADE;
