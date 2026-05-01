# Advanced PostgreSQL Patterns

Production-grade patterns for performance, reliability, and observability.

---

## 1. Connection Pooling (PgBouncer)

```ini
# /etc/pgbouncer/pgbouncer.ini
[databases]
myapp = host=localhost port=5432 dbname=myapp

[pgbouncer]
pool_mode = transaction          # CRITICAL: transaction mode for web apps
max_client_conn = 1000           # app connections to PgBouncer
default_pool_size = 20           # actual PG connections (keep this low!)
min_pool_size = 5
reserve_pool_size = 5
reserve_pool_timeout = 3
server_idle_timeout = 600
log_connections = 0              # disable in production (verbose)
log_disconnections = 0
```

**Rule**: `max PG connections = (2 × CPU cores) + number of disks`.  
A 4-core server → 10 PG connections is usually optimal. PgBouncer multiplexes 1000 app connections onto 10 PG connections transparently.

```python
# With asyncpg: pool per process
pool = await asyncpg.create_pool(
    DSN,
    min_size=2,
    max_size=10,              # per process, goes through PgBouncer
    command_timeout=30,
    server_settings={
        'application_name': 'myapp-worker',  # visible in pg_stat_activity
    }
)
```

---

## 2. Table Partitioning

```sql
-- For tables that will exceed 50M rows or require data archival

-- Time-based partitioning (most common)
CREATE TABLE events (
  id         BIGSERIAL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  type       TEXT NOT NULL,
  payload    JSONB
) PARTITION BY RANGE (created_at);

-- Monthly partitions
CREATE TABLE events_2025_01 PARTITION OF events
  FOR VALUES FROM ('2025-01-01') TO ('2025-02-01');
CREATE TABLE events_2025_02 PARTITION OF events
  FOR VALUES FROM ('2025-02-01') TO ('2025-03-01');

-- Auto-create partitions with pg_partman
CREATE EXTENSION pg_partman;
SELECT partman.create_parent(
  'public.events',     -- parent table
  'created_at',        -- partition column
  'native',            -- partitioning type
  'monthly'            -- interval
);

-- BRIN index: 100x smaller than BTree for monotonically increasing columns
CREATE INDEX idx_events_created_brin ON events USING BRIN (created_at);

-- Drop old partitions (instant, no DELETE overhead)
DROP TABLE events_2024_01;   -- instant even for 100M rows
```

---

## 3. Observability Without External APM

```sql
-- Enable query statistics (add to postgresql.conf)
-- shared_preload_libraries = 'pg_stat_statements'
CREATE EXTENSION IF NOT EXISTS pg_stat_statements;

-- Top 10 slowest queries (by total time)
SELECT
  round(total_exec_time::numeric, 2) AS total_ms,
  calls,
  round(mean_exec_time::numeric, 2)  AS avg_ms,
  round(stddev_exec_time::numeric, 2) AS stddev_ms,
  left(query, 120)                    AS query_preview
FROM pg_stat_statements
ORDER BY total_exec_time DESC
LIMIT 10;

-- Cache hit rate (target > 99%)
SELECT
  sum(heap_blks_hit)::float /
  (sum(heap_blks_hit) + sum(heap_blks_read)) AS cache_hit_ratio
FROM pg_statio_user_tables;

-- Table bloat (indicates need for VACUUM)
SELECT schemaname, tablename,
  pg_size_pretty(pg_total_relation_size(schemaname||'.'||tablename)) AS total_size,
  n_dead_tup,
  n_live_tup,
  round(n_dead_tup::numeric / NULLIF(n_live_tup + n_dead_tup, 0) * 100, 1) AS dead_ratio
FROM pg_stat_user_tables
WHERE n_dead_tup > 1000
ORDER BY n_dead_tup DESC;

-- Long-running queries (alert if > 30s)
SELECT pid, now() - pg_stat_activity.query_start AS duration, query, state
FROM pg_stat_activity
WHERE (now() - pg_stat_activity.query_start) > INTERVAL '30 seconds'
  AND state != 'idle';

-- Lock waits (indicates contention)
SELECT
  blocked.pid, blocked.query AS blocked_query,
  blocking.pid AS blocking_pid, blocking.query AS blocking_query
FROM pg_stat_activity blocked
JOIN pg_stat_activity blocking ON blocking.pid = ANY(pg_blocking_pids(blocked.pid))
WHERE cardinality(pg_blocking_pids(blocked.pid)) > 0;
```

---

## 4. Distributed Locking

```sql
-- Replace distributed lock managers (Redlock, ZooKeeper) with advisory locks

-- Session-level lock (held until connection closes or explicit release)
SELECT pg_try_advisory_lock(hashtext('payment-processor-job-42'));
-- Returns true if acquired, false if already locked by another session

-- Transaction-level lock (released automatically on COMMIT/ROLLBACK)
SELECT pg_try_advisory_xact_lock(42);

-- Use case: ensure only one instance processes a job
CREATE OR REPLACE FUNCTION process_report(report_id BIGINT) RETURNS BOOLEAN AS $$
BEGIN
  -- Try to acquire lock (key = report_id)
  IF NOT pg_try_advisory_xact_lock(report_id) THEN
    RETURN FALSE;  -- another instance is processing this report
  END IF;

  -- Lock acquired: safe to proceed
  UPDATE reports SET status = 'processing', started_at = NOW()
  WHERE id = report_id;

  -- Lock released automatically at end of transaction
  RETURN TRUE;
END;
$$ LANGUAGE plpgsql;
```

---

## 5. Upsert Patterns

```sql
-- Replace "check if exists + insert or update" application logic

-- Simple upsert
INSERT INTO users (email, name, updated_at)
VALUES ($1, $2, NOW())
ON CONFLICT (email) DO UPDATE
  SET name = EXCLUDED.name, updated_at = NOW()
RETURNING *;

-- Conditional upsert: only update if newer
INSERT INTO product_prices (product_id, price, effective_at)
VALUES ($1, $2, $3)
ON CONFLICT (product_id) DO UPDATE
  SET price = EXCLUDED.price, effective_at = EXCLUDED.effective_at
  WHERE EXCLUDED.effective_at > product_prices.effective_at;  -- only if newer

-- Insert-only (ignore conflict)
INSERT INTO events (type, payload)
VALUES ($1, $2)
ON CONFLICT DO NOTHING;

-- Bulk upsert (thousands of rows efficiently)
INSERT INTO inventory (sku, quantity, updated_at)
SELECT * FROM UNNEST($1::text[], $2::int[], $3::timestamptz[]) AS t(sku, quantity, updated_at)
ON CONFLICT (sku) DO UPDATE
  SET quantity = EXCLUDED.quantity, updated_at = EXCLUDED.updated_at;
```

---

## 6. Efficient Pagination

```sql
-- ❌ OFFSET-based: gets slower as offset increases (full scan to skip N rows)
SELECT * FROM orders ORDER BY created_at DESC LIMIT 20 OFFSET 10000;

-- ✅ Cursor-based: O(log n) regardless of page position
-- First page:
SELECT id, amount, created_at FROM orders
ORDER BY created_at DESC, id DESC
LIMIT 20;

-- Next page (pass last row's created_at and id as cursor):
SELECT id, amount, created_at FROM orders
WHERE (created_at, id) < ($last_created_at, $last_id)  -- cursor condition
ORDER BY created_at DESC, id DESC
LIMIT 20;

-- For APIs: return cursor in response
{
  "data": [...],
  "next_cursor": "2025-01-15T10:30:00Z__42891"
}
```

---

## 7. Generated Columns for Computed Values

```sql
-- Replace application-level computed fields with DB-generated columns
-- Auto-updated, indexed, no application code required

ALTER TABLE orders ADD COLUMN total_with_tax NUMERIC(12,2)
  GENERATED ALWAYS AS (subtotal * (1 + tax_rate)) STORED;

ALTER TABLE users ADD COLUMN full_name TEXT
  GENERATED ALWAYS AS (first_name || ' ' || last_name) STORED;

-- Index the generated column
CREATE INDEX idx_orders_total ON orders (total_with_tax);

-- Search by computed value (no function call overhead)
SELECT * FROM orders WHERE total_with_tax > 1000;
```
