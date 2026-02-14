# pgfr_record

Core flight recorder extension for PostgreSQL. Continuously samples database state in the background so you can answer "what was happening in my database?" after the fact.

## What it does

pgfr_record installs a set of tables, views, and pg_cron jobs that continuously capture PostgreSQL system state. It uses UNLOGGED ring buffers for high-frequency sampling of wait events, active sessions, and locks, and durable snapshot tables for periodic capture of WAL activity, checkpoints, I/O, table and index stats, query stats, replication state, and configuration. Data flows from ring buffers into archives and aggregates for longer retention.

## Key features

- **Continuous background sampling** via pg_cron -- no external agents or sidecars
- **Ring buffers** (UNLOGGED) for real-time wait events, active sessions, and lock contention
- **Durable snapshots** every 5 minutes: WAL, checkpoints, I/O, tables, indexes, statements, replication, configuration
- **Aggregates and archives** for longer retention (7 days for archives, 30 days for snapshots)
- **Safety mechanisms**: circuit breaker, load shedding, adaptive sampling, DDL lock check, replica lag check
- **Collection modes**: normal, light, emergency, kill
- **Configurable profiles**: default, production_safe, development, troubleshooting, minimal_overhead
- **Delta views**: snapshot-over-snapshot changes for trend analysis

## Requirements

- PostgreSQL 15, 16, or 17
- `pg_cron` extension
- Superuser privileges for installation
- Optional: `pg_stat_statements` for query-level analysis

## Install

```sql
\i _record/install.sql
SELECT pgfr.enable();
```

Or from the command line:

```bash
psql --single-transaction -f _record/install.sql
psql -c "SELECT pgfr.enable();"
```

## Quick start

```sql
-- Check health
SELECT * FROM pgfr.health_check();

-- View recent wait events
SELECT * FROM pgfr.recent_waits;

-- View recent active sessions
SELECT * FROM pgfr.recent_activity;

-- View recent lock contention
SELECT * FROM pgfr.recent_locks;

-- Compare two snapshots
SELECT * FROM pgfr.compare(1, 5);

-- Wait event summary over a time range
SELECT * FROM pgfr.wait_summary(now() - '1 hour', now());

-- Snapshot-over-snapshot deltas
SELECT * FROM pgfr.deltas;
```

## Key views

| View                         | Description                      |
|------------------------------|----------------------------------|
| `pgfr.deltas`                | Snapshot-over-snapshot changes   |
| `pgfr.recent_waits`          | Wait events from ring buffer     |
| `pgfr.recent_activity`       | Active sessions from ring buffer |
| `pgfr.recent_locks`          | Lock contention from ring buffer |
| `pgfr.recent_idle_in_transaction` | Idle-in-transaction sessions |
| `pgfr.recent_replication`    | Replication status               |
| `pgfr.recent_vacuum_progress`| Vacuum operations in progress    |
| `pgfr.archiver_status`       | WAL archiving status             |

## Key functions

| Function                   | Description                                  |
|----------------------------|----------------------------------------------|
| `pgfr.enable()`            | Start collection jobs                        |
| `pgfr.disable()`           | Stop collection jobs                         |
| `pgfr.health_check()`      | System health status                         |
| `pgfr.compare(id1, id2)`   | Compare two snapshots                        |
| `pgfr.wait_summary(start, end)` | Wait event breakdown                    |
| `pgfr.set_mode(mode)`      | Set collection mode                          |
| `pgfr.apply_profile(name)` | Apply a configuration profile                |
| `pgfr.list_profiles()`     | List available profiles                      |
| `pgfr.ring_buffer_health()`| Ring buffer status                           |
| `pgfr.cleanup()`           | Manual retention cleanup                     |

## Profiles

| Profile            | Sample Interval | Use Case                               |
|--------------------|-----------------|----------------------------------------|
| `default`          | 180s            | General purpose monitoring             |
| `production_safe`  | 300s            | Production with maximum safety margins |
| `development`      | 180s            | Staging and development                |
| `troubleshooting`  | 60s             | Active incident response               |
| `minimal_overhead` | 300s            | Resource-constrained systems           |

## Related extensions

- [pgfr_analyze](https://database.dev/dventimi/pgfr_analyze) -- reporting, anomaly detection, time-travel forensics
- [pgfr_control](https://database.dev/dventimi/pgfr_control) -- vacuum diagnostics, scale factor tuning, bloat analysis

See the [top-level README](https://github.com/dventimisupabase/pg-flight-recorder/blob/main/README.md) and [REFERENCE.md](https://github.com/dventimisupabase/pg-flight-recorder/blob/main/REFERENCE.md) for full documentation.
