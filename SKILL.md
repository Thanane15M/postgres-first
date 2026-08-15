---
name: postgres-first
description: >
  Evaluates whether PostgreSQL can satisfy database, cache, queue, search, vector,
  background-job, pub/sub, rate-limit, audit, or multi-tenant requirements before
  adding another data service. Use when designing or simplifying backend
  architecture, reviewing Redis/MongoDB/Elasticsearch/vector-store usage, or
  planning a migration toward PostgreSQL-native patterns.
---

# PostgreSQL-First Architecture

Use PostgreSQL first **only when measured requirements show it is sufficient**.
This skill is an evidence gate, not a mandate to replace every specialized system.

## Non-negotiable rule

Before adding, removing, or replacing a data service, collect evidence for:

1. **Performance** — expected peak throughput, p95/p99 latency, data size, query shape, growth margin.
2. **Semantics** — ordering, replay, fan-out, durability, delivery guarantees, consistency and availability needs.
3. **Operations** — blast radius, restore objectives, team skill, regional/compliance constraints, cost and failure isolation.

If these are unknown, classify the decision as `NOT_PROVEN`; do not claim that PostgreSQL is sufficient.

## Decision workflow

### 1. Identify the workload

Classify the requirement before choosing infrastructure:

| Workload | PostgreSQL-native candidate | Keep/split a specialist when… |
|---|---|---|
| Flexible documents | `JSONB` + GIN | access patterns or scale are proven unsuitable |
| Durable work queue | row table + `FOR UPDATE SKIP LOCKED` | broker semantics, partition isolation, replay/fan-out or throughput require it |
| Cache | ordinary/unlogged tables, materialized views | latency or independent failure isolation requires an external cache |
| Full-text/fuzzy search | `tsvector`, GIN, `pg_trgm` | relevance, indexing scale or search features exceed measured targets |
| Vector retrieval | `pgvector` | measured recall/latency/cost justify a dedicated vector service |
| Schedules | `pg_cron` + durable jobs | orchestration graph complexity or execution isolation requires a workflow engine |
| Pub/sub wake-ups | `LISTEN/NOTIFY` backed by durable rows | durable streams, replay or large fan-out are required |
| Rate limits | atomic counters/window tables | global edge latency or extremely high write rates require another store |
| Audit trail | append-only relational tables | regulatory isolation or immutable external retention requires another system |

### 2. Define the SLO and exit criteria

Write the boundary before implementation. Example:

```text
queue_slo:
  sustained_jobs_per_second: 250
  p99_claim_latency_ms: 100
  replay_required: false
  cross_region_active_active: false
  max_recovery_time_minutes: 15

exit_to_specialist_if:
  - p99 exceeds target under representative load
  - database contention harms transactional workloads
  - required semantics cannot be implemented economically
```

### 3. Benchmark the representative path

Do not substitute row-count folklore or generic CPU formulas for measurement.
Connection counts, pool sizes, partition thresholds, cache policies and indexes are workload-specific.
Use `EXPLAIN (ANALYZE, BUFFERS)`, `pg_stat_statements`, realistic concurrency, and failure tests.

### 4. Test failure modes

At minimum, test:

- worker crash after claim and before completion;
- duplicate delivery/idempotency;
- transaction rollback;
- lock contention;
- pool exhaustion;
- restore/recovery path for durable state;
- tenant isolation when RLS is used;
- degradation of the primary workload when auxiliary work grows.

### 5. Record the decision

Return one of:

- `VERIFIED_POSTGRES_FIT` — representative tests meet explicit requirements with headroom.
- `PARTIAL` — promising pattern, incomplete evidence.
- `KEEP_SPECIALIST` — a specialist provides required semantics/isolation economically.
- `NOT_PROVEN` — requirements or runtime evidence are missing.

Never use `production-ready` as a synonym for “the SQL parses.”

## Core patterns

### Durable queue

Use a durable row as the source of truth and claim work transactionally:

```sql
WITH claimed AS (
  SELECT id
  FROM job_queue
  WHERE status IN ('pending', 'retrying')
    AND run_at <= now()
  ORDER BY priority DESC, run_at, id
  LIMIT 1
  FOR UPDATE SKIP LOCKED
)
UPDATE job_queue AS q
SET status = 'processing',
    started_at = now(),
    attempts = attempts + 1
FROM claimed
WHERE q.id = claimed.id
RETURNING q.*;
```

`SKIP LOCKED` is appropriate for queue-like consumers; it intentionally does not provide a consistent general-purpose snapshot.

### Idempotency

Use a unique business/idempotency key rather than an in-memory duplicate guard:

```sql
INSERT INTO processed_events (idempotency_key, payload)
VALUES ($1, $2)
ON CONFLICT (idempotency_key) DO NOTHING
RETURNING id;
```

No returned row means the event was already accepted.

### Cache

Use reconstructible cache tables only when losing them is acceptable. `UNLOGGED` tables are not durable and are not replicated to standbys; never use them for authoritative state.

### Search

Start with PostgreSQL search when the corpus and relevance requirements fit. Benchmark before replacing a dedicated search engine; do not use document count alone as an exit threshold.

### Observability

Enable `pg_stat_statements` when the platform supports it, then measure planning/execution statistics and query concentration. Remember that it requires `shared_preload_libraries` and a server restart to add or remove.

## Guardrails

- PostgreSQL is not a CDN, email deliverability platform, model-serving runtime, or universal event log.
- `LISTEN/NOTIFY` is a wake-up signal, not durable storage.
- Queue rows need retry, timeout/reaper, dead-letter and idempotency semantics.
- Multi-tenant examples need explicit RLS policies and tests under a non-bypass role.
- `pg_cron`, `pgvector`, `pg_partman`, PostGIS and similar extensions are deployment capabilities, not assumptions.
- Managed PostgreSQL providers may restrict extensions and superuser operations.
- A simpler stack is valuable only if it still meets reliability and recovery requirements.

## Read the references only when needed

- Advanced patterns: [`patterns/README.md`](patterns/README.md)
- Migration playbooks: [`migrations/README.md`](migrations/README.md)
- Failure patterns: [`anti-patterns/README.md`](anti-patterns/README.md)
- Preserved pre-refactor skill: [`references/SKILL.pre-2026-08-15.md`](references/SKILL.pre-2026-08-15.md)
- Verification matrix and source dates: [`VERIFICATION.md`](VERIFICATION.md)
- Reproducible eval cases: [`evals/cases.jsonl`](evals/cases.jsonl)

## Required verification before a recommendation

1. Run `python scripts/validate_skill.py`.
2. Run the PostgreSQL runtime tests in `tests/` against PostgreSQL 18 or the target production major.
3. Record measured workload evidence and provider constraints.
4. State any untested property as `NOT_PROVEN`.
5. Re-run validation after changing PostgreSQL major versions, extensions, or referenced upstream behavior.
