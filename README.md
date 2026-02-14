# pgfr_record

Server-side flight recorder for PostgreSQL. Answers "what was happening in my database?"

## Structure

Three extensions, each in its own subdirectory:

| Directory | Extension | Schema | Purpose |
|-----------|-----------|--------|---------|
| `_record/` | `pgfr_record` | `pgfr` | Core: tables, collection, scheduling, ring buffers |
| `_analyze/` | `pgfr_analyze` | `pgfr_analyze` | Optional: reporting, anomaly detection, time travel |
| `_control/` | `pgfr_control` | `pgfr_control` | Optional: vacuum diagnostics, scale factor tuning, bloat |

## Install

Requires PostgreSQL 15+ with pg_cron.

Download from [GitHub Releases](https://github.com/dventimisupabase/pg-flight-recorder/releases/latest) or clone the repo, then:

```bash
# Core (tables, collection, scheduling)
psql --single-transaction -f _record/install.sql
```

```bash
# Control (optional — vacuum diagnostics, scale factor tuning, bloat analysis)
psql --single-transaction -f _control/install.sql
```

```bash
# Reporting & analysis (optional)
psql --single-transaction -f _analyze/install.sql
```

## Export

With default retention: ~2.5GB uncompressed, ~150MB compressed.

```bash
# Without compression
pg_dump -d your_database -n pgfr --data-only -f pgfr_data.sql
```

```bash
# With compression (PostgreSQL 16+)
pg_dump -d your_database -n pgfr --data-only --compress=gzip:9 -f pgfr_data.sql.gz
```

```bash
# With compression (PostgreSQL 15)
pg_dump -d your_database -n pgfr --data-only | gzip > pgfr_data.sql.gz
```

## Uninstall

```bash
# Remove everything (destructive)
psql --single-transaction -f _record/uninstall.sql
```

```bash
# Remove only control functions (keeps core + data)
psql --single-transaction -f _control/uninstall.sql
```

```bash
# Remove only reporting functions (keeps core + data)
psql --single-transaction -f _analyze/uninstall.sql
```

## Reference

See [REFERENCE.md](https://github.com/dventimisupabase/pg-flight-recorder/blob/main/REFERENCE.md) for configuration, functions, and details.
