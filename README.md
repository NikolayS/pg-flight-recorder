# pg-flight-recorder

[![GitHub release](https://img.shields.io/github/v/release/dventimisupabase/pg-flight-recorder)](https://github.com/dventimisupabase/pg-flight-recorder/releases/latest)
[![Test Suite](https://github.com/dventimisupabase/pg-flight-recorder/actions/workflows/test.yml/badge.svg)](https://github.com/dventimisupabase/pg-flight-recorder/actions/workflows/test.yml)
[![Lint](https://github.com/dventimisupabase/pg-flight-recorder/actions/workflows/lint.yml/badge.svg)](https://github.com/dventimisupabase/pg-flight-recorder/actions/workflows/lint.yml)

Server-side flight recorder for PostgreSQL. Answers "what was happening in my database?"

## Install

```bash
# Core (tables, collection, scheduling)
psql -f install.sql

# Reporting & analysis (optional)
psql -f reporting.sql
```

Requires PostgreSQL 15+ with pg_cron.

Also available on [database.dev](https://database.dev):

- [dventimi/pg_flight_recorder](https://database.dev/dventimi/pg_flight_recorder) (core)
- [dventimi/pg_flight_recorder_reporting](https://database.dev/dventimi/pg_flight_recorder_reporting) (reporting)

## Use

```sql
SELECT flight_recorder.report('1 hour');
```

That's it. It runs automatically. The report tells you what happened.

## Uninstall

```bash
psql -f uninstall.sql
```

## Export

With default retention: ~2.5GB uncompressed, ~150MB compressed.

```bash
# Without compression
pg_dump -d your_database -n flight_recorder --data-only -f flight_recorder_data.sql

# With compression (PostgreSQL 16+)
pg_dump -d your_database -n flight_recorder --data-only --compress=gzip:9 -f flight_recorder_data.sql.gz

# With compression (PostgreSQL 15)
pg_dump -d your_database -n flight_recorder --data-only | gzip > flight_recorder_data.sql.gz
```

See [pglite/README.md](pglite/README.md) for offline analysis with PGLite.

## Reference

See [REFERENCE.md](REFERENCE.md) for configuration, functions, and details.
