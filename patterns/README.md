# Advanced PostgreSQL patterns

These patterns are starting points. Every numeric setting is workload- and provider-dependent; benchmark before adopting a value in production.

## 1. Connection pooling

Use a pool when application concurrency is much larger than the number of database sessions the workload can sustain efficiently.

Example PgBouncer shape:

```ini
[databases]
myapp = host=localhost port=5432 dbname=myapp

[pgbouncer]
pool_mode = transaction
max_client_conn = 1000
default_pool_size = 20
reserve_pool_size = 5
server_idle_timeout = 600
```

**Do not treat these numbers as defaults for every deployment.** Determine pool sizes from representative load, transaction duration, server resources, provider limits, reserved administrative capacity and saturation tests.

For application pools, remember that the effective database connection count is roughly the sum of the maximum pools across concurrently running processes/instances unless an external pooler multiplexes them.

## 2. Partitioning

Partition for a demonstrated operational reason: pruning, retention, maintenance windows, bulk lifecycle operations or very large indexes. Do not partition only because a table crossed an arbitrary row count.

```sql
CREATE TABLE events (
  id bigint GENERATED ALWAYS AS IDENTITY,
  created_at timestamptz NOT NULL DEFAULT now(),
  type text NOT NULL,
  payload jsonb
) PARTITION BY RANGE (created_at);

CREATE TABLE events_2026_08 PARTITION OF events
  FOR VALUES FROM ('2026-08-01') TO ('2026-09-01');
```

For append-correlated timestamp columns, evaluate BRIN against B-tree using the actual query workload:

```sql
CREATE INDEX events_created_brin ON events USING brin (created_at);
```

## 3. Query observability

`pg_stat_statements` tracks planning/execution statistics. It requires the module to be loaded through `shared_preload_libraries`; adding/removing it requires a server restart.

```sql
CREATE EXTENSION IF NOT EXISTS pg_stat_statements;

SELECT
  calls,
  total_exec_time,
  mean_exec_time,
  rows,
  left(query, 160) AS query_preview
FROM pg_stat_statements
ORDER BY total_exec_time DESC
LIMIT 20;
```

Use this to identify workload concentration before adding caches, replicas or search systems.

## 4. Locking

Use transaction-scoped advisory locks when the protected resource can be represented by a stable key and the critical section belongs inside a database transaction.

```sql
SELECT pg_try_advisory_xact_lock(42);
```

Do not use advisory locks as a substitute for row constraints, unique constraints or idempotency keys.

For queue-like tables, `FOR UPDATE SKIP LOCKED` lets concurrent consumers skip rows another transaction already locked. It intentionally gives an inconsistent view and is not suitable for arbitrary reads.

## 5. Upserts and idempotency

```sql
INSERT INTO users (email, name, updated_at)
VALUES ($1, $2, now())
ON CONFLICT (email) DO UPDATE
SET name = excluded.name,
    updated_at = now();
```

For externally retried operations, prefer a dedicated unique idempotency key so duplicate acceptance is observable.

## 6. Cursor pagination

Avoid large `OFFSET` scans for deep, ordered pagination. Use a stable total ordering with a tie-breaker:

```sql
SELECT id, amount, created_at
FROM orders
WHERE (created_at, id) < ($1, $2)
ORDER BY created_at DESC, id DESC
LIMIT 20;
```

The cursor must preserve all ordering columns and the ordering must be deterministic.

## 7. Generated columns

Generated columns are useful for deterministic row-local expressions that benefit from indexing or central consistency.

```sql
ALTER TABLE orders
ADD COLUMN total_with_tax numeric(12,2)
GENERATED ALWAYS AS (subtotal * (1 + tax_rate)) STORED;
```

Avoid pushing volatile business rules into generated expressions when they require historical versioning or external context.

## 8. RLS verification

Enabling RLS is not enough. Test both allowed and forbidden access through a role that cannot bypass RLS.

Minimum evidence:

- owner/admin path behaves as designed;
- tenant A can read/write its own rows;
- tenant A cannot read/write tenant B rows;
- missing tenant context fails closed;
- service roles with `BYPASSRLS` are explicitly bounded and audited.

## 9. Durable queue completeness

A queue pattern is not complete with `SKIP LOCKED` alone. Define:

- idempotency key;
- retry policy and maximum attempts;
- visibility/processing timeout;
- reaper for abandoned `processing` rows;
- dead-letter/failure inspection;
- observability and alerting;
- retention/cleanup;
- backpressure;
- shutdown behavior.

## 10. Extension assumptions

`pg_cron`, `pgvector`, PostGIS and `pg_partman` may not be installed or permitted by a managed provider. Treat extension availability as an environment capability and verify it before prescribing a pattern.

## Verification

See [`../VERIFICATION.md`](../VERIFICATION.md) and run the executable checks in [`../tests/`](../tests/).

The pre-2026-08-15 version of this file is preserved at [`README.pre-2026-08-15.md`](README.pre-2026-08-15.md).
