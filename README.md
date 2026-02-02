# pg-flight-recorder

[![GitHub release](https://img.shields.io/github/v/release/dventimisupabase/pg-flight-recorder)](https://github.com/dventimisupabase/pg-flight-recorder/releases/latest)
[![Test Suite](https://github.com/dventimisupabase/pg-flight-recorder/actions/workflows/test.yml/badge.svg)](https://github.com/dventimisupabase/pg-flight-recorder/actions/workflows/test.yml)
[![Lint](https://github.com/dventimisupabase/pg-flight-recorder/actions/workflows/lint.yml/badge.svg)](https://github.com/dventimisupabase/pg-flight-recorder/actions/workflows/lint.yml)

Server-side flight recorder for PostgreSQL. Answers "what was happening in my database?"

## Install

```bash
psql -f install.sql
```

Requires PostgreSQL 15+ with pg_cron.

## Use

```sql
SELECT flight_recorder.report('1 hour');
```

That's it. It runs automatically. The report tells you what happened.

## Uninstall

```bash
psql -f uninstall.sql
```

## Reference

See [REFERENCE.md](REFERENCE.md) for configuration, functions, and details.
