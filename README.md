# pg_flight_recorder

Server-side flight recorder for PostgreSQL. Answers "what was happening in my database?"

## Install

Requires PostgreSQL 15+ with pg_cron.

### Option A: From SQL files

Download from [GitHub Releases](https://github.com/dventimisupabase/pg-flight-recorder/releases/latest) or clone the repo, then:

```bash
# Core (tables, collection, scheduling)
psql -f install.sql

# Reporting & analysis (optional)
psql -f reporting.sql
```

### Option B: From database.dev

Install via the [dbdev](https://database.dev) package manager:

```sql
-- Core
SELECT dbdev.install('dventimi-pg_flight_recorder');

-- Reporting & analysis (optional, requires core)
SELECT dbdev.install('dventimi-pg_flight_recorder_reporting');
```

## Use

```sql
SELECT flight_recorder_reporting.report('1 hour');
```

That's it. It runs automatically. The report tells you what happened.

## Uninstall

```bash
# Remove everything (destructive)
psql -f uninstall.sql

# Remove only reporting functions (keeps core + data)
psql -f uninstall_reporting.sql
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

## Reference

See [REFERENCE.md](REFERENCE.md) for configuration, functions, and details.
