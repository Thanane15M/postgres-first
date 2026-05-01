# Migration Guides: Redis, MongoDB, n8n, Elasticsearch → PostgreSQL

Practical, step-by-step migration paths proven in production.

---

## MIGRATION 1: Redis → PostgreSQL

### When to migrate
- Redis is used for: cache, sessions, simple queues, rate limiting, pub/sub
- Your Redis instance costs > $50/month or requires dedicated ops attention
- You want one fewer service to backup, monitor, and secure

### Step 1 — Audit current Redis usage

```bash
# What are you actually using Redis for?
redis-cli info keyspace          # key distribution
redis-cli --scan --pattern '*'   # list all keys (careful on prod)
redis-cli info commandstats      # which commands dominate
```

Common finding: 80% of Redis usage is cache + session. Both replaceable in < 1 day.

### Step 2 — Replace cache

```sql
-- Run once
CREATE UNLOGGED TABLE cache (
  key        TEXT PRIMARY KEY,
  value      JSONB NOT NULL,
  expires_at TIMESTAMPTZ NOT NULL
);
CREATE INDEX idx_cache_expires ON cache (expires_at)
  WHERE expires_at < NOW() + INTERVAL '1 year';

-- Schedule cleanup (pg_cron or app-level)
-- cron.schedule('cache-cleanup', '0 * * * *', 'DELETE FROM cache WHERE expires_at < NOW()');
```

```python
# Before (redis-py)
redis.setex('user:42:profile', 3600, json.dumps(profile))
profile = json.loads(redis.get('user:42:profile') or 'null')

# After (asyncpg / psycopg3)
async def cache_set(key: str, value: dict, ttl_seconds: int):
    await conn.execute("""
        INSERT INTO cache (key, value, expires_at)
        VALUES ($1, $2, NOW() + $3 * INTERVAL '1 second')
        ON CONFLICT (key) DO UPDATE
          SET value = EXCLUDED.value, expires_at = EXCLUDED.expires_at
    """, key, json.dumps(value), ttl_seconds)

async def cache_get(key: str) -> dict | None:
    row = await conn.fetchrow(
        "SELECT value FROM cache WHERE key = $1 AND expires_at > NOW()", key
    )
    return json.loads(row['value']) if row else None
```

### Step 3 — Replace session store

```sql
CREATE TABLE sessions (
  token      TEXT PRIMARY KEY DEFAULT gen_random_uuid()::text,
  user_id    BIGINT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  data       JSONB NOT NULL DEFAULT '{}',
  ip_address INET,
  user_agent TEXT,
  expires_at TIMESTAMPTZ NOT NULL DEFAULT NOW() + INTERVAL '30 days',
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_sessions_user ON sessions (user_id);
CREATE INDEX idx_sessions_expires ON sessions (expires_at)
  WHERE expires_at > NOW();
```

### Step 4 — Replace queues

See `SKILL.md` → Section 2 (job_queue with `FOR UPDATE SKIP LOCKED`).

Migration: export pending Redis queue items → insert into job_queue table.

```python
# One-time migration script
pending = redis.lrange('queue:emails', 0, -1)
with pg_conn.cursor() as cur:
    for item in pending:
        cur.execute(
            "INSERT INTO job_queue (queue, payload) VALUES ('emails', %s)",
            (item,)
        )
pg_conn.commit()
redis.delete('queue:emails')
```

### Step 5 — Replace pub/sub

See `SKILL.md` → Section 6 (`LISTEN/NOTIFY`).

### Step 6 — Remove Redis

```bash
# Verify zero Redis traffic for 48h
redis-cli info stats | grep total_commands_processed

# Then:
docker stop redis && docker rm redis
# Remove from compose, helm chart, etc.
```

**Typical outcome**: $100-300/month eliminated, 1 fewer service to operate.

---

## MIGRATION 2: MongoDB → PostgreSQL

### When to migrate
- MongoDB Atlas costs > $100/month for your workload
- Your schema is more structured than you thought when you chose Mongo
- You want transactions, foreign keys, and JOINs

### Step 1 — Export from MongoDB

```bash
mongoexport \
  --uri="mongodb+srv://user:pass@cluster/db" \
  --collection=orders \
  --type=json \
  --out=orders.json
```

### Step 2 — Create hybrid table (JSONB preserves Mongo flexibility)

```sql
-- Hybrid approach: structured columns + JSONB for the rest
CREATE TABLE orders (
  id         TEXT PRIMARY KEY,               -- preserve Mongo _id
  tenant_id  UUID,                           -- extract if exists
  status     TEXT,                           -- frequently queried fields
  amount     NUMERIC(12,2),
  created_at TIMESTAMPTZ,
  data       JSONB NOT NULL DEFAULT '{}'     -- everything else
);

CREATE INDEX idx_orders_status  ON orders (status, created_at DESC);
CREATE INDEX idx_orders_data    ON orders USING GIN (data);
CREATE INDEX idx_orders_tenant  ON orders (tenant_id);
```

### Step 3 — Import

```python
import json, psycopg2
from datetime import datetime

conn = psycopg2.connect(PG_DSN)
cur = conn.cursor()

with open('orders.json') as f:
    for line in f:
        doc = json.loads(line)
        cur.execute("""
            INSERT INTO orders (id, status, amount, created_at, data)
            VALUES (%s, %s, %s, %s, %s)
            ON CONFLICT (id) DO NOTHING
        """, (
            str(doc['_id']),
            doc.get('status'),
            doc.get('amount'),
            doc.get('createdAt'),
            json.dumps({k: v for k, v in doc.items()
                       if k not in ('_id', 'status', 'amount', 'createdAt')})
        ))

conn.commit()
```

### Step 4 — Translate queries

```python
# MongoDB → PostgreSQL query translation

# find({status: "paid"})
"WHERE status = 'paid'"

# find({amount: {$gt: 100, $lt: 500}})
"WHERE amount > 100 AND amount < 500"

# find({tags: {$in: ["urgent", "vip"]}})
"WHERE data->'tags' ?| ARRAY['urgent', 'vip']"

# find({}).sort({createdAt: -1}).limit(20)
"ORDER BY created_at DESC LIMIT 20"

# aggregate([{$group: {_id: "$status", count: {$sum: 1}}}])
"SELECT status, COUNT(*) FROM orders GROUP BY status"

# updateOne({_id: id}, {$set: {status: "shipped"}})
"UPDATE orders SET status = 'shipped', data = jsonb_set(data, '{status}', '\"shipped\"') WHERE id = $1"
```

---

## MIGRATION 3: n8n → `pg_cron` + `job_queue`

### When to migrate
- n8n is running on a VPS with no redundancy
- Your n8n workflows are mostly: "at time X, query DB Y, do Z"
- You want simpler ops and zero dependency on a Node.js process

### Step 1 — Audit n8n workflows

Categorize each workflow:
- **Scheduled trigger + DB operations** → `pg_cron` (< 1 hour to replace)
- **HTTP webhooks → DB operations** → Application code (FastAPI endpoint)
- **Multi-step with external APIs** → `job_queue` + worker
- **Complex integrations (Slack, Gmail)** → Keep in n8n or replace with worker

### Step 2 — Install pg_cron

```sql
-- On managed PG (Supabase, RDS, etc.) it's often pre-installed
CREATE EXTENSION IF NOT EXISTS pg_cron;

-- Verify
SELECT * FROM cron.job;
```

### Step 3 — Replace scheduled workflows

```sql
-- n8n: "Every night at 2am, delete old sessions"
SELECT cron.schedule(
  'delete-expired-sessions',   -- job name
  '0 2 * * *',                 -- cron expression
  $$DELETE FROM sessions WHERE expires_at < NOW()$$
);

-- n8n: "Every hour, refresh stats"
SELECT cron.schedule(
  'refresh-stats',
  '0 * * * *',
  $$REFRESH MATERIALIZED VIEW CONCURRENTLY mv_dashboard_stats$$
);

-- n8n: "Every 5 minutes, process pending invoices"
SELECT cron.schedule(
  'process-invoices',
  '*/5 * * * *',
  $$
    INSERT INTO job_queue (queue, payload)
    SELECT 'invoice-processing', json_build_object('invoice_id', id)::jsonb
    FROM invoices
    WHERE status = 'ready_to_send'
      AND created_at < NOW() - INTERVAL '5 minutes'
  $$
);

-- List all scheduled jobs
SELECT jobid, schedule, command, active FROM cron.job;

-- View execution history
SELECT * FROM cron.job_run_details ORDER BY start_time DESC LIMIT 20;

-- Disable a job
SELECT cron.unschedule('refresh-stats');
```

### Step 4 — Replace n8n HTTP triggers with job workers

```python
# Replace n8n HTTP → DB → External API workflows
# with a simple worker that polls job_queue

import asyncio, asyncpg, json, httpx

async def worker(pool: asyncpg.Pool):
    async with pool.acquire() as conn:
        while True:
            # Claim one job
            job = await conn.fetchrow("""
                WITH claimed AS (
                  SELECT id FROM job_queue
                  WHERE queue = 'invoice-processing'
                    AND status IN ('pending', 'retrying')
                    AND run_at <= NOW()
                  ORDER BY priority DESC, run_at
                  LIMIT 1
                  FOR UPDATE SKIP LOCKED
                )
                UPDATE job_queue
                SET status = 'processing', started_at = NOW(), attempts = attempts + 1
                FROM claimed WHERE job_queue.id = claimed.id
                RETURNING *
            """)

            if not job:
                await asyncio.sleep(5)
                continue

            try:
                await process_invoice(json.loads(job['payload']))
                await conn.execute(
                    "UPDATE job_queue SET status='done', finished_at=NOW() WHERE id=$1",
                    job['id']
                )
            except Exception as e:
                await conn.execute("""
                    UPDATE job_queue
                    SET status = CASE WHEN attempts >= max_attempts THEN 'failed' ELSE 'retrying' END,
                        error = $2,
                        run_at = NOW() + INTERVAL '1 second' * POWER(2, attempts)
                    WHERE id = $1
                """, job['id'], str(e))
```

---

## MIGRATION 4: Elasticsearch → `tsvector` + `pg_trgm`

### When to migrate
- Elasticsearch cluster costs > $200/month
- Your index has < 10 million documents
- Your queries are: full-text search, autocomplete, filters + search combined

### Step 1 — Add search columns

```sql
CREATE EXTENSION IF NOT EXISTS pg_trgm;
CREATE EXTENSION IF NOT EXISTS unaccent;

-- Add generated search vector (auto-updated, zero application code)
ALTER TABLE products
  ADD COLUMN search_vec TSVECTOR
  GENERATED ALWAYS AS (
    setweight(to_tsvector('english', unaccent(coalesce(name, ''))),        'A') ||
    setweight(to_tsvector('english', unaccent(coalesce(description, ''))), 'B') ||
    setweight(to_tsvector('english', unaccent(coalesce(brand, ''))),       'C')
  ) STORED;

CREATE INDEX idx_products_fts  ON products USING GIN (search_vec);
CREATE INDEX idx_products_trgm ON products USING GIN (name gin_trgm_ops);
```

### Step 2 — Translate Elasticsearch queries

```python
# ES query DSL → PostgreSQL SQL

# ES: {"query": {"match": {"name": "coffee maker"}}}
sql = """
    SELECT *, ts_rank(search_vec, query) AS score
    FROM products, websearch_to_tsquery('english', $1) AS query
    WHERE search_vec @@ query
    ORDER BY score DESC LIMIT $2
"""

# ES: {"query": {"multi_match": {"query": "...", "fields": ["name^3", "description"]}}}
# → Already handled by setweight() A/B/C in the generated column

# ES: {"query": {"bool": {"must": [...], "filter": [{range...}]}}}
sql = """
    SELECT *, ts_rank(search_vec, query) AS score
    FROM products, websearch_to_tsquery('english', $1) AS query
    WHERE search_vec @@ query
      AND price BETWEEN $2 AND $3        -- filter
      AND category = $4                  -- filter
    ORDER BY score DESC
"""

# ES: fuzzy query (handles typos)
sql = """
    SELECT name, similarity(name, $1) AS sim
    FROM products
    WHERE name % $1
    ORDER BY sim DESC LIMIT 10
"""

# ES: autocomplete / prefix
sql = """
    SELECT DISTINCT name
    FROM products
    WHERE name ILIKE $1 || '%'
    ORDER BY name LIMIT 10
"""
```

### Step 3 — Remove Elasticsearch

After confirming search quality is equivalent (run both in parallel for 1 week, compare results):

```bash
# Stop ES cluster
docker-compose stop elasticsearch kibana
# Remove from infrastructure
```

**Typical outcome**: $200-800/month eliminated, significant RAM freed on application servers.
