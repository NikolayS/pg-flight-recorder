# pg-flight-recorder — Development Cost Estimate

**Analysis Date**: 2026-03-06
**Codebase**: pg-flight-recorder (3 PostgreSQL extensions for flight-recorder-style monitoring)

---

## Codebase Metrics

### Lines of Code

| Category | Files | Lines | Notes |
|----------|-------|-------|-------|
| **SQL — Core Extension** (`_record/install.sql`) | 1 | 4,786 | 47 functions, 16 tables, 8 views |
| **SQL — Analyze Extension** (`_analyze/install.sql`) | 1 | 5,052 | 38 functions, 1 view |
| **SQL — Control Extension** (`_control/install.sql`) | 1 | 1,150 | 15 functions, 1 table |
| **SQL — Uninstall scripts** | 3 | 35 | DROP SCHEMA CASCADE |
| **SQL — Tests** (pgTAP) | 20 | 7,964 | 15 record, 1 control, 4 analyze |
| **Shell Scripts** (`test.sh`) | 1 | 192 | Multi-PG-version Docker test runner |
| **Docker / CI / Config** | 13 | 600 | Dockerfile, Compose, GH Actions, controls |
| **HTML** (landing page) | 1 | 1,579 | index.html with Supabase branding |
| **Markdown** (docs) | 6 | 1,431 | READMEs, REFERENCE.md, CLAUDE.md |
| **TOTAL** | **47** | **22,789** | |

### Functional Code Summary (excluding docs, HTML, config)

| Category | Lines |
|----------|-------|
| Extension SQL (install files) | 10,988 |
| Test SQL (pgTAP) | 7,964 |
| Shell / Docker / CI | 792 |
| **Total functional code** | **19,744** |

### Complexity Factors

**PostgreSQL Internals Accessed (16 system views/extensions)**:

- `pg_stat_activity`, `pg_stat_database`, `pg_stat_database_conflicts`
- `pg_stat_bgwriter`, `pg_stat_checkpointer`, `pg_stat_wal`
- `pg_stat_archiver`, `pg_stat_io`, `pg_stat_replication`
- `pg_stat_user_tables`, `pg_stat_user_indexes`
- `pg_stat_statements`, `pg_stat_statements_info`
- `pg_stat_progress_vacuum`
- `pgstattuple` (extension for tuple-level stats)
- `pg_cron` (job scheduling extension)

**Advanced SQL/PL/pgSQL Features**:

- Ring buffer implementation with configurable retention
- Delta column computation (rate-of-change between snapshots)
- Anomaly detection algorithms (z-score, percentile-based)
- Time-travel queries (point-in-time reconstruction)
- Blast radius analysis (impact assessment)
- Query storm detection
- XID wraparound monitoring
- OID exhaustion monitoring
- Autovacuum observation and control
- Vacuum scale factor tuning
- Cross-schema extension architecture (3 independent but coordinated extensions)
- Additive-only schema evolution strategy
- Multi-PostgreSQL-version compatibility (PG 15/16/17)

**Architecture**:

- 100 PL/pgSQL functions across 3 extensions
- 17 tables, 9 views
- 20 pgTAP test files with comprehensive coverage
- Docker-based multi-version test infrastructure
- GitHub Actions CI/CD (test, lint, publish, release, pages)

---

## Development Time Estimate

### Base Development Hours

This project is specialized **database systems programming** — not typical application code. PL/pgSQL functions that interact with PostgreSQL internals, implement ring buffers, compute deltas, and detect anomalies require deep domain expertise.

| Component | Lines | Productivity Rate | Hours |
|-----------|-------|-------------------|-------|
| Core extension (`_record`) — snapshot collection, ring buffers, scheduling, delta computation | 4,786 | 12-18 lines/hr (system-level DB programming) | 266-399 |
| Analyze extension (`_analyze`) — anomaly detection, time travel, blast radius, reporting | 5,052 | 15-20 lines/hr (complex business logic + DB internals) | 253-337 |
| Control extension (`_control`) — vacuum diagnostics, scale factor tuning | 1,150 | 12-18 lines/hr (system-level DB programming) | 64-96 |
| Test suite (pgTAP) | 7,964 | 25-35 lines/hr (comprehensive test code) | 228-319 |
| Shell / Docker / CI | 792 | 15-25 lines/hr (DevOps/infra) | 32-53 |
| **Base coding total** | **19,744** | | **843-1,204** |

**Midpoint base estimate**: **1,024 hours**

### Overhead Multipliers

| Overhead Category | Percentage | Hours |
|-------------------|-----------|-------|
| Architecture & design (3-extension architecture, schema evolution strategy, cross-version compat) | +20% | 205 |
| Debugging & troubleshooting (PG internals, version-specific behavior) | +30% | 307 |
| Code review & refactoring (evident from git history — major schema rename, API restructuring) | +15% | 154 |
| Documentation (REFERENCE.md, READMEs, COMMENT ON statements throughout) | +10% | 102 |
| Integration & testing (multi-PG-version Docker testing, pgTAP framework setup) | +20% | 205 |
| Learning curve (PostgreSQL internals, pg_stat views, pgstattuple, pg_cron integration) | +15% | 154 |
| **Total overhead** | **+110%** | **1,127** |

### Total Estimated Development Hours

| | Hours |
|---|---|
| Base coding | 1,024 |
| Overhead | 1,127 |
| **Total** | **2,151** |

---

## Realistic Calendar Time (with Organizational Overhead)

Developers don't code 40 hours/week. Accounting for standups, team syncs, 1:1s, sprint ceremonies, code reviews, Slack/email, context switching, and admin overhead:

| Company Type | Coding Efficiency | Coding Hrs/Week | Calendar Weeks | Calendar Time |
|--------------|-------------------|-----------------|----------------|---------------|
| Solo/Startup (lean) | 65% | 26 hrs | 83 weeks | ~19 months |
| Growth Company | 55% | 22 hrs | 98 weeks | ~23 months |
| Enterprise | 45% | 18 hrs | 120 weeks | ~28 months |
| Large Bureaucracy | 35% | 14 hrs | 154 weeks | ~3 years |

---

## Market Rate Research

### Senior PostgreSQL Developer Rates (2025-2026, US Market)

| Tier | Hourly Rate | Context |
|------|-------------|---------|
| Low-end | $100/hr | Experienced PG developer, freelance platforms, solid PL/pgSQL |
| Mid-range | $135/hr | Senior PG specialist with internals knowledge, monitoring experience |
| High-end | $175/hr | PG extension developer/consultant, deep pg_catalog expertise |

**Recommended rate for this project**: **$135/hr**

*Rationale*: This project requires a rare combination — deep PostgreSQL internals (16 system views), PL/pgSQL fluency, extension architecture, ring buffer algorithms, anomaly detection, and multi-version compatibility. This narrows the talent pool significantly beyond general PostgreSQL developers.

Sources: ZipRecruiter, Glassdoor, Arc.dev, Toptal, PayScale, Rise 2026 Freelancer Report

---

## Total Engineering Cost Estimate

| Scenario | Hourly Rate | Total Hours | **Total Cost** |
|----------|-------------|-------------|----------------|
| Low-end | $100/hr | 2,151 | **$215,100** |
| Mid-range | $135/hr | 2,151 | **$290,385** |
| High-end | $175/hr | 2,151 | **$376,425** |

**Recommended Estimate (Engineering Only)**: **$215,000 - $376,000**

---

## Full Team Cost (All Roles)

Real products require more than engineering. Estimated fully-loaded team costs:

| Company Stage | Team Multiplier | Engineering Cost (mid) | **Full Team Cost** |
|---------------|-----------------|------------------------|-------------------|
| Solo/Founder | 1.0x | $290,385 | **$290,385** |
| Lean Startup | 1.45x | $290,385 | **$421,058** |
| Growth Company | 2.2x | $290,385 | **$638,847** |
| Enterprise | 2.65x | $290,385 | **$769,520** |

### Role Breakdown (Growth Company Example)

| Role | Ratio | Hours | Rate | Cost |
|------|-------|-------|------|------|
| Engineering | 1.00x | 2,151 hrs | $135/hr | $290,385 |
| Product Management | 0.30x | 645 hrs | $150/hr | $96,750 |
| UX/UI Design | 0.25x | 538 hrs | $125/hr | $67,250 |
| Engineering Management | 0.15x | 323 hrs | $175/hr | $56,525 |
| QA/Testing | 0.20x | 430 hrs | $100/hr | $43,000 |
| Project Management | 0.10x | 215 hrs | $125/hr | $26,875 |
| Technical Writing | 0.05x | 108 hrs | $100/hr | $10,800 |
| DevOps/Platform | 0.15x | 323 hrs | $150/hr | $48,450 |
| **TOTAL** | **2.20x** | **4,733 hrs** | | **$640,035** |

---

## Claude ROI Analysis

### Project Timeline

| Metric | Value |
|--------|-------|
| First commit | 2026-02-14 |
| Latest commit | 2026-02-25 |
| Total calendar span | 12 days |
| Active development days | 3 days |
| Total commits | 51 (45 human, 6 bot) |

### Development Sessions

| Session | Date | Commits | Est. Hours | Focus |
|---------|------|---------|------------|-------|
| 1 | Feb 14 | 10 | ~3 hrs | Initial release, docs, publishing workflow |
| 2 | Feb 20 AM | 16 | ~4 hrs | Safety cleanup, dead code removal, pg_cron fixes |
| 3 | Feb 20 PM | 18 | ~4 hrs | Delta columns, schema rename, API refactoring |
| 4 | Feb 25 | 7 | ~3 hrs | Landing page, GitHub Pages deployment |
| **Total** | | **51** | **~14 hrs** | |

**Note**: The git history shows 14 hours of commit activity across 12 calendar days. However, substantial pre-existing design work, PostgreSQL internals research, and architecture decisions preceded the first commit. Estimated total active development time including pre-commit work: **20-30 hours**.

### Value per Development Hour

| Value Basis | Total Value | Active Hours (est.) | Value per Hour |
|-------------|-------------|---------------------|----------------|
| Engineering only (mid) | $290,385 | 25 hrs | **$11,615/hr** |
| Full team equiv (Growth Co) | $640,035 | 25 hrs | **$25,601/hr** |
| Full team equiv (Enterprise) | $769,520 | 25 hrs | **$30,781/hr** |

### Speed vs. Human Developer

| Metric | Value |
|--------|-------|
| Estimated human dev hours | 2,151 hours |
| Actual development hours | ~25 hours |
| **Speed multiplier** | **~86x** |

### Cost Comparison

| Metric | Value |
|--------|-------|
| Human developer cost (at $135/hr) | $290,385 |
| Actual development cost (estimated) | ~$500 (tools, compute, time) |
| **Net savings** | **~$289,885** |
| **ROI** | **~580x** |

---

## Grand Total Summary

| Metric | Solo/Founder | Lean Startup | Growth Co | Enterprise |
|--------|-------------|--------------|-----------|------------|
| Calendar time (1 dev) | ~19 months | ~23 months | ~28 months | ~3 years |
| Total human hours | 2,151 | 3,119 | 4,733 | 5,700 |
| **Total cost** | **$290,385** | **$421,058** | **$640,035** | **$769,520** |

---

## Assumptions

1. Rates based on US market averages (2025-2026) for PostgreSQL specialists
2. Full-time equivalent allocation for all roles
3. Includes complete implementation of all three extensions with tests
4. The 110% overhead multiplier reflects the genuine complexity of PostgreSQL internals programming — this is not application-layer code
5. Does not include:
   - Marketing & sales
   - Legal & compliance
   - Office/equipment
   - Hosting/infrastructure (Supabase, etc.)
   - Ongoing maintenance post-launch
   - Community support and issue triage
6. Multi-PG-version support (15/16/17) adds significant testing overhead
7. The project author clearly has deep PostgreSQL expertise, which would take years to develop — this domain knowledge is not captured in the line count

---

*Generated by Claude Code on 2026-03-06*
