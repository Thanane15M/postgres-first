# Verification matrix

Last evidence review: **2026-08-15**.

This file separates documentation claims from runtime proof. A claim is `VERIFIED` only for the scope named below; broader production suitability still depends on the target workload.

| Claim | Status | Evidence / boundary |
|---|---|---|
| `FOR UPDATE SKIP LOCKED` can avoid row-lock contention for queue-like consumers | VERIFIED | PostgreSQL 18 `SELECT` documentation explicitly describes queue-like use; `tests/queue_concurrency.sh` reproduces two consumers selecting different rows while one row is locked. |
| `pg_stat_statements` tracks planning/execution statistics | VERIFIED | PostgreSQL 18 extension documentation; deployment requires `shared_preload_libraries` and query IDs. |
| `max_connections` has one universal CPU/disk formula | REJECTED | PostgreSQL documents a configured connection maximum and resource implications, not a universal sizing formula. Pool/concurrency sizing must be measured. |
| PostgreSQL can replace every cache, broker, search engine or vector store | REJECTED | The skill requires workload evidence and explicit exit criteria. |
| SQL examples parse | VERIFIED_IN_CI | `scripts/validate_markdown.py` parses fenced SQL with `pglast`; this is syntax evidence only. |
| Core PostgreSQL-native examples execute on PostgreSQL 18 | VERIFIED_IN_CI when quality job is green | `tests/runtime.sql`. |
| Queue consumers skip an already locked row | VERIFIED_IN_CI when quality job is green | `tests/queue_concurrency.sh`. |
| A specific production workload meets its SLO on PostgreSQL | NOT_PROVEN by this repository | Requires representative application load, provider configuration, extensions, data and failure tests. |

## Source-of-truth references

- PostgreSQL 18 `SELECT` / locking documentation: `https://www.postgresql.org/docs/18/sql-select.html`
- PostgreSQL 18 connection settings: `https://www.postgresql.org/docs/18/runtime-config-connection.html`
- PostgreSQL 18 `pg_stat_statements`: `https://www.postgresql.org/docs/18/pgstatstatements.html`

## Re-verification triggers

Re-run the evidence review when any of these change:

- supported PostgreSQL major version;
- SQL pattern or extension assumptions;
- queue/locking semantics;
- CI PostgreSQL image;
- externally referenced upstream documentation;
- a claim moves from general guidance to a numeric threshold.

## Evidence vocabulary

- `VERIFIED` — directly supported by authoritative documentation or a reproducible test for the stated scope.
- `VERIFIED_IN_CI` — the repository includes a deterministic check; inspect the current workflow run before treating it as green.
- `PARTIAL` — some evidence exists but a material property is untested.
- `NOT_PROVEN` — insufficient runtime evidence.
- `REJECTED` — claim intentionally removed because it was too broad or unsupported.
