# pgfr_control

Vacuum control and bloat analysis extension for [pgfr_record](https://database.dev/dventimi/pgfr_record). Provides closed-loop vacuum diagnostics, autovacuum scale factor recommendations, and table bloat estimation.

## What it does

pgfr_control reads the table snapshot data collected by pgfr_record and computes dead tuple growth rates, vacuum operating modes, and recommended autovacuum scale factors. It classifies vacuum health, estimates table bloat without requiring pgstattuple, and monitors OID consumption. It is non-invasive: it reads snapshots, computes recommendations, and reports -- it never auto-applies changes.

## Key features

- **Closed-loop vacuum control** with state machine: normal, catch_up, and safety modes based on XID age and dead tuple trends
- **Dead tuple growth rate and trend analysis** via linear regression over snapshot history
- **Autovacuum scale factor recommendations** computed from actual dead tuple accumulation rates
- **Vacuum diagnostics**: classifies tables as NOT_SCHEDULED, RUNNING_BUT_LOSING, BLOCKED, or HEALTHY with actionable guidance
- **Table bloat estimation** without pgstattuple -- uses dead tuple ratio and size metrics
- **OID consumption rate** and exhaustion time estimation
- **Table size growth rate** tracking for detecting bloat accumulation
- **Non-invasive**: reads snapshots and recommends changes, never auto-applies

## Requirements

- [pgfr_record](https://database.dev/dventimi/pgfr_record) must be installed first

## Install

```sql
-- Install core first if not already installed
\i _record/install.sql
SELECT pgfr.enable();

-- Then install control
\i _control/install.sql
```

## Quick start

```sql
-- Check vacuum mode for a table
SELECT * FROM pgfr_control.vacuum_control_mode('my_table'::regclass);

-- Get vacuum diagnostic for a table
SELECT * FROM pgfr_control.vacuum_diagnostic('my_table'::regclass);

-- Get recommended autovacuum scale factor
SELECT * FROM pgfr_control.compute_recommended_scale_factor('my_table'::regclass);

-- Full vacuum control report
SELECT * FROM pgfr_control.vacuum_control_report(now() - '1 hour', now());

-- Bloat report with trends
SELECT * FROM pgfr_control.bloat_report('24 hours');

-- Check OID exhaustion timeline
SELECT pgfr_control.time_to_oid_exhaustion();
```

## Functions

### Vacuum control

| Function                                | Description                                       |
|-----------------------------------------|---------------------------------------------------|
| `vacuum_control_mode(oid)`              | Determine operating mode (normal/catch_up/safety) |
| `compute_recommended_scale_factor(oid)` | Recommend autovacuum scale factor                 |
| `vacuum_diagnostic(oid)`                | Classify vacuum health with actionable guidance   |
| `vacuum_control_report(start, end)`     | Vacuum control recommendations for all tables     |

### Dead tuple analysis

| Function                                 | Description                                         |
|------------------------------------------|-----------------------------------------------------|
| `dead_tuple_growth_rate(oid, interval)`  | Dead tuple accumulation rate (tuples/second)        |
| `dead_tuple_trend(oid, interval)`        | Dead tuple trend via linear regression              |
| `time_to_budget_exhaustion(oid, budget)` | Estimate time until autovacuum threshold is reached |

### Bloat estimation

| Function                        | Description                                          |
|---------------------------------|------------------------------------------------------|
| `estimate_table_bloat(oid)`     | Estimate table bloat without pgstattuple             |
| `bloat_report(interval)`        | Bloat report with size trends and recommendations    |
| `table_size_growth_rate(oid, interval)` | Table size growth rate (bytes/second)        |

### OID monitoring

| Function                        | Description                          |
|---------------------------------|--------------------------------------|
| `oid_consumption_rate(interval)`| OID usage rate (OIDs/second)         |
| `time_to_oid_exhaustion()`      | Estimate time until OID exhaustion   |

## Vacuum diagnostic modes

| Diagnostic          | Meaning                                                      |
|---------------------|--------------------------------------------------------------|
| `NOT_SCHEDULED`     | Autovacuum hasn't run -- scale factor may be too high        |
| `RUNNING_BUT_LOSING`| Vacuum runs but dead tuples grow faster than cleanup         |
| `BLOCKED`           | Vacuum is blocked by long-running transactions or locks      |
| `HEALTHY`           | Vacuum is keeping up with dead tuple accumulation            |

## Related extensions

- [pgfr_record](https://database.dev/dventimi/pgfr_record) -- core snapshot collection (required)
- [pgfr_analyze](https://database.dev/dventimi/pgfr_analyze) -- reporting, anomaly detection, time-travel forensics

See the [top-level README](https://github.com/dventimisupabase/pg-flight-recorder/blob/main/README.md) and [REFERENCE.md](https://github.com/dventimisupabase/pg-flight-recorder/blob/main/REFERENCE.md) for full documentation.
