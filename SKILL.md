---
name: postgres-first
description: >
  PostgreSQL-First Architecture — radical stack simplification expert.
  Activate whenever a project mentions a database, cache, queue, search engine,
  vector store, background jobs, pub/sub, rate limiting, audit trails, or any
  backend infrastructure. Replaces Redis, MongoDB, Elasticsearch, Pinecone,
  RabbitMQ, Celery, n8n, and 20+ SaaS services with native PostgreSQL patterns.
  Trigger phrases: "what cache should I use", "which queue", "I need a search
  engine", "vector database", "background jobs", "simplify my stack", "audit my
  architecture", "migrate from Redis/Mongo/n8n", "too many services", "how to
  do full-text search", "rate limiting", "multi-tenant", "row level security".
---

# PostgreSQL-First Architecture

> **"Every external service is a deployment, a bill, a 3am page, and a skill gap to hire for.  
> PostgreSQL already does it. Use it."**

**This skill makes one argument, relentlessly:** for 95% of applications at 95% of companies,
PostgreSQL can replace every data infrastructure service you think you need. This is not theory.
It is documented practice from production systems.

---

## RULE ZERO — The Scale Test

Before recommending any external service, answer these three questions:

| Question | Threshold for external service |
|---|---|
| **Request rate** | > 50,000 req/sec *sustained* on this specific operation? |
| **Team size** | > 8 engineers with dedicated infra capacity? |
| **Regulatory requirement** | Does compliance mandate service isolation? |

**If 2+ answers are NO → PostgreSQL native. No discussion.**

Most teams that think they need Redis have < 5,000 req/sec and 3 engineers.
Most teams that think they need Elasticsearch have < 100,000 documents.
Most teams that think they need Kafka have < 10,000 events/sec.

The replacement matrix below covers each case.

---

## THE COMPLETE REPLACEMENT MATRIX

### 1. Document Store / NoSQL → `JSONB`

```sql
-- Replaces: MongoDB, DynamoDB, Firestore, CouchDB

CREATE TABLE entities (
  id          BIGSERIAL PRIMARY KEY,
  tenant_id   UUID NOT NULL,                    -- multi-tenant from birth
  type        TEXT NOT NULL,                    -- your "collection" name
  data        JSONB NOT NULL DEFAULT '{}',
  created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- GIN index: makes ANY key inside data queryable at ~2ms
CREATE INDEX idx_entities_data  ON entities USING GIN (data);
CREATE INDEX idx_entities_type  ON entities (type, created_at DESC);
CREATE INDEX idx_entities_tenant ON entities (tenant_id, type);

-- Query any field without schema migration
SELECT * FROM entities
WHERE type = 'invoice'
  AND data @> '{"status": "paid", "currency": "EUR"}'
  AND tenant_id = 'acme-corp-uuid';

-- Nested update without fetching the document
UPDATE entities
SET data = jsonb_set(data, '{address,city}', '"Paris"'),
    updated_at = NOW()
WHERE id = 42;

-- Aggregate inside JSONB (replaces aggregation pipelines)
SELECT
  data->>'country' AS country,
  COUNT(*) AS count,
  SUM((data->>'amount')::numeric) AS total
FROM entities
WHERE type = 'order'
GROUP BY data->>'country'
ORDER BY total DESC;
```

**MongoDB query mapping:**
```
db.find({status: "paid"})          → WHERE data @> '{"status":"paid"}'
db.find({amount: {$gt: 100}})      → WHERE (data->>'amount')::numeric > 100
db.updateOne({}, {$set: {x: 1}})   → UPDATE SET data = jsonb_set(data, '{x}', '1')
db.aggregate([{$group: {_id: "$x"}}]) → GROUP BY data->>'x'
```

---

### 2. Message Queue / Background Jobs → `FOR UPDATE SKIP LOCKED`

```sql
-- Replaces: Redis + BullMQ, RabbitMQ + Celery, SQS, n8n queues

CREATE TABLE job_queue (
  id           BIGSERIAL PRIMARY KEY,
  queue        TEXT NOT NULL DEFAULT 'default',
  payload      JSONB NOT NULL,
  status       TEXT NOT NULL DEFAULT 'pending'
               CHECK (status IN ('pending','processing','done','failed','retrying')),
  priority     INT NOT NULL DEFAULT 0,          -- higher = more urgent
  attempts     SMALLINT NOT NULL DEFAULT 0,
  max_attempts SMALLINT NOT NULL DEFAULT 3,
  error        TEXT,                            -- last error message
  run_at       TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  started_at   TIMESTAMPTZ,
  finished_at  TIMESTAMPTZ,
  created_at   TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Partial index: only pending jobs, keeps index tiny
CREATE INDEX idx_jobs_dequeue ON job_queue (queue, priority DESC, run_at)
  WHERE status IN ('pending', 'retrying');

-- Worker: atomically claim one job (race-condition proof, no distributed lock needed)
WITH claimed AS (
  SELECT id FROM job_queue
  WHERE queue = 'default'
    AND status IN ('pending', 'retrying')
    AND run_at <= NOW()
  ORDER BY priority DESC, run_at
  LIMIT 1
  FOR UPDATE SKIP LOCKED          -- other workers skip this row instantly
)
UPDATE job_queue
SET status = 'processing', started_at = NOW(), attempts = attempts + 1
FROM claimed
WHERE job_queue.id = claimed.id
RETURNING *;

-- Mark done
UPDATE job_queue SET status = 'done', finished_at = NOW() WHERE id = $1;

-- Retry with exponential backoff on failure
UPDATE job_queue
SET status = CASE WHEN attempts >= max_attempts THEN 'failed' ELSE 'retrying' END,
    error = $2,
    run_at = NOW() + (INTERVAL '1 second' * POWER(2, attempts))  -- 2s, 4s, 8s, 16s...
WHERE id = $1
RETURNING status;

-- Dead letter queue: jobs that exhausted retries
SELECT * FROM job_queue
WHERE status = 'failed'
ORDER BY finished_at DESC;
```

**Schedule recurring jobs with `pg_cron`:**
```sql
-- Replaces: Celery beat, n8n schedules, cron daemons, APScheduler
CREATE EXTENSION IF NOT EXISTS pg_cron;

-- Run daily at 02:00 UTC
SELECT cron.schedule('nightly-cleanup', '0 2 * * *',
  $$DELETE FROM job_queue WHERE status = 'done' AND finished_at < NOW() - INTERVAL '7 days'$$
);

-- Every 5 minutes
SELECT cron.schedule('heartbeat', '*/5 * * * *',
  $$INSERT INTO job_queue (queue, payload) VALUES ('monitoring', '{"type":"heartbeat"}')$$
);
```

---

### 3. Cache → `UNLOGGED TABLE` + `MATERIALIZED VIEW`

```sql
-- Replaces: Redis cache, Memcached, Varnish

-- Ephemeral key-value cache (no WAL = maximum write speed)
CREATE UNLOGGED TABLE cache (
  key        TEXT PRIMARY KEY,
  value      JSONB NOT NULL,
  expires_at TIMESTAMPTZ NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_cache_expires ON cache (expires_at);

-- Set with TTL
INSERT INTO cache (key, value, expires_at)
VALUES ($1, $2, NOW() + $3::INTERVAL)
ON CONFLICT (key) DO UPDATE
  SET value = EXCLUDED.value, expires_at = EXCLUDED.expires_at;

-- Get (returns NULL if expired)
SELECT value FROM cache
WHERE key = $1 AND expires_at > NOW();

-- Cleanup (run via pg_cron every hour)
DELETE FROM cache WHERE expires_at < NOW();

-- For heavy computed results: Materialized View (refreshed concurrently)
CREATE MATERIALIZED VIEW mv_dashboard_stats AS
SELECT
  date_trunc('day', created_at) AS day,
  COUNT(*)                       AS new_users,
  SUM(amount)                    AS revenue,
  AVG(response_time_ms)          AS avg_response_ms
FROM events
WHERE created_at > NOW() - INTERVAL '30 days'
GROUP BY 1
WITH DATA;

CREATE UNIQUE INDEX ON mv_dashboard_stats (day);

-- Refresh without locking reads (CONCURRENTLY requires unique index)
REFRESH MATERIALIZED VIEW CONCURRENTLY mv_dashboard_stats;
```

**Rate limiting (replaces Redis INCR + EXPIRE):**
```sql
CREATE TABLE rate_limits (
  key         TEXT NOT NULL,
  window_start TIMESTAMPTZ NOT NULL,
  count       INT NOT NULL DEFAULT 1,
  PRIMARY KEY (key, window_start)
);

-- Atomic increment, returns current count
INSERT INTO rate_limits (key, window_start, count)
VALUES ($1, date_trunc('minute', NOW()), 1)
ON CONFLICT (key, window_start) DO UPDATE
  SET count = rate_limits.count + 1
RETURNING count;
-- If returned count > limit → reject request
```

---

### 4. Full-Text & Fuzzy Search → `tsvector` + `pg_trgm`

```sql
-- Replaces: Elasticsearch, Algolia, Typesense, MeiliSearch, Solr

CREATE EXTENSION IF NOT EXISTS pg_trgm;
CREATE EXTENSION IF NOT EXISTS unaccent;

-- Generated column: auto-updated on every write
ALTER TABLE products ADD COLUMN search_vec TSVECTOR
  GENERATED ALWAYS AS (
    setweight(to_tsvector('english', coalesce(name, '')),       'A') ||
    setweight(to_tsvector('english', coalesce(description, '')), 'B') ||
    setweight(to_tsvector('english', coalesce(tags::text, '')), 'C')
  ) STORED;

CREATE INDEX idx_products_fts  ON products USING GIN (search_vec);
CREATE INDEX idx_products_trgm ON products USING GIN (name gin_trgm_ops);

-- Full-text search with ranking
SELECT
  id, name,
  ts_rank(search_vec, query)    AS rank,
  ts_headline('english', description, query,
    'MaxWords=20,MinWords=5')   AS excerpt
FROM products, websearch_to_tsquery('english', $1) AS query
WHERE search_vec @@ query
ORDER BY rank DESC, name
LIMIT 20;

-- Fuzzy search: handles typos ("javascrpit" → "javascript")
SELECT name, similarity(name, $1) AS sim
FROM products
WHERE name % $1             -- pg_trgm operator: similar
ORDER BY sim DESC
LIMIT 10;

-- Combined: full-text OR fuzzy (comprehensive search)
SELECT DISTINCT ON (id) id, name, ts_rank(search_vec, query) AS rank
FROM products, websearch_to_tsquery('english', $1) AS query
WHERE search_vec @@ query
   OR name % $1
ORDER BY id, rank DESC;
```

---

### 5. Vector / Semantic Search → `pgvector`

```sql
-- Replaces: Pinecone, Weaviate, Chroma, Qdrant, Milvus

CREATE EXTENSION IF NOT EXISTS vector;

CREATE TABLE embeddings (
  id          BIGSERIAL PRIMARY KEY,
  source_type TEXT NOT NULL,                   -- 'document', 'product', 'message'
  source_id   BIGINT NOT NULL,
  chunk_index INT NOT NULL DEFAULT 0,          -- for chunked documents
  content     TEXT NOT NULL,
  embedding   vector(1536),                   -- OpenAI / Cohere / custom
  metadata    JSONB NOT NULL DEFAULT '{}',
  created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE (source_type, source_id, chunk_index)
);

-- HNSW index: sub-millisecond ANN search at millions of vectors
CREATE INDEX idx_embeddings_hnsw ON embeddings
  USING hnsw (embedding vector_cosine_ops)
  WITH (m = 16, ef_construction = 64);        -- tune m for recall vs speed

-- Semantic search
SELECT
  source_type, source_id, content,
  1 - (embedding <=> $1::vector) AS cosine_similarity,
  metadata
FROM embeddings
WHERE source_type = 'document'                -- optional filter
ORDER BY embedding <=> $1::vector
LIMIT 5;

-- Hybrid search: semantic + keyword (RAG best practice)
WITH semantic AS (
  SELECT source_id, 1 - (embedding <=> $1::vector) AS score
  FROM embeddings ORDER BY embedding <=> $1::vector LIMIT 20
),
keyword AS (
  SELECT id AS source_id, ts_rank(search_vec, query) AS score
  FROM documents, websearch_to_tsquery('english', $2) AS query
  WHERE search_vec @@ query LIMIT 20
)
SELECT COALESCE(s.source_id, k.source_id) AS id,
       COALESCE(s.score, 0) * 0.7 + COALESCE(k.score, 0) * 0.3 AS hybrid_score
FROM semantic s FULL JOIN keyword k USING (source_id)
ORDER BY hybrid_score DESC
LIMIT 5;
```

---

### 6. Real-Time / Pub-Sub → `LISTEN / NOTIFY`

```sql
-- Replaces: Redis pub/sub, Ably, Pusher, Socket.io server-side state

-- Publish from anywhere in the app or a trigger
SELECT pg_notify('orders', json_build_object(
  'event', 'new_order',
  'order_id', NEW.id,
  'amount', NEW.amount
)::text);

-- Trigger-based: automatic on table change
CREATE OR REPLACE FUNCTION notify_order_change() RETURNS TRIGGER AS $$
BEGIN
  PERFORM pg_notify('orders', json_build_object(
    'event', TG_OP,
    'id', NEW.id,
    'status', NEW.status
  )::text);
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_orders_notify
  AFTER INSERT OR UPDATE ON orders
  FOR EACH ROW EXECUTE FUNCTION notify_order_change();
```

```python
# Python listener (asyncpg) — replaces Redis subscriber
import asyncio, asyncpg, json

async def listen():
    conn = await asyncpg.connect(DSN)
    await conn.add_listener('orders', lambda *args: handle(args[3]))
    await asyncio.sleep(float('inf'))

def handle(payload: str):
    event = json.loads(payload)
    print(f"Order {event['id']} → {event['status']}")
```

---

### 7. Multi-Tenant Isolation → Row Level Security

```sql
-- The authorization logic belongs to the data layer, not the middleware.

ALTER TABLE invoices ENABLE ROW LEVEL SECURITY;
ALTER TABLE users    ENABLE ROW LEVEL SECURITY;
ALTER TABLE documents ENABLE ROW LEVEL SECURITY;

-- Tenant isolation: each row is owned by a tenant
CREATE POLICY tenant_isolation ON invoices
  USING (tenant_id = current_setting('app.tenant_id')::uuid);

-- Role-based access within a tenant
CREATE POLICY role_write ON invoices
  FOR INSERT WITH CHECK (
    current_setting('app.tenant_id')::uuid = tenant_id AND
    current_setting('app.role') IN ('admin', 'accountant')
  );

-- Application sets context before every query:
-- SET LOCAL app.tenant_id = 'acme-corp-uuid';
-- SET LOCAL app.role = 'accountant';

-- Performance: index on tenant_id is mandatory with RLS
CREATE INDEX idx_invoices_tenant ON invoices (tenant_id);
CREATE INDEX idx_users_tenant    ON users (tenant_id);
```

---

### 8. Audit Trail → Temporal Tables

```sql
-- Replaces: event sourcing services, audit SaaS, custom log tables

-- Automatic history on any table
CREATE TABLE orders_history (LIKE orders INCLUDING ALL);
ALTER TABLE orders_history ADD COLUMN
  changed_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  changed_by  TEXT,
  change_type TEXT CHECK (change_type IN ('INSERT','UPDATE','DELETE'));

CREATE OR REPLACE FUNCTION audit_orders() RETURNS TRIGGER AS $$
BEGIN
  INSERT INTO orders_history
  SELECT OLD.*, NOW(), current_setting('app.user_email', true), TG_OP;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_orders_audit
  AFTER UPDATE OR DELETE ON orders
  FOR EACH ROW EXECUTE FUNCTION audit_orders();

-- Query: who changed order #42 and when?
SELECT changed_at, changed_by, change_type, status, amount
FROM orders_history
WHERE id = 42
ORDER BY changed_at DESC;
```

---

## HOW THIS SKILL RESPONDS

For every architecture question, structure the answer as:

### 🔍 Scale Check
Answer the 3 Rule Zero questions. Verdict: PostgreSQL-First or justified exception.

### 🔧 Native Pattern
The specific PostgreSQL feature/extension that replaces the requested service.

### 💻 Production Code
Complete, copy-paste ready SQL/code. Zero placeholders. Zero "TODO: implement this".

### 📊 ROI
- **Monthly cost eliminated**: $X in removed services
- **Complexity reduction**: N services → 1
- **Ops benefit**: unified backup, monitoring, alerting

### ⚠️ Honest Limits
When PostgreSQL genuinely cannot compete and a specific threshold where external services are justified.

---

## ARCHITECTURE AUDIT CHECKLIST

When reviewing an existing system:

```
□ How many distinct data services? (target: ≤ 2)
□ Is Redis used only for cache/session? → Replace with UNLOGGED TABLE
□ Is Redis used for queues? → Replace with FOR UPDATE SKIP LOCKED
□ Is MongoDB used for flexible schema? → Replace with JSONB
□ Is Elasticsearch used for < 10M docs? → Replace with tsvector + pg_trgm
□ Is Pinecone/Chroma used? → Replace with pgvector
□ Are n8n/Celery/Airflow used for simple jobs? → Replace with pg_cron + job_queue
□ Is RLS enabled on all tenant-scoped tables?
□ Is pg_cron installed for recurring tasks?
□ Are Materialized Views used instead of app-level caching?
□ Is LISTEN/NOTIFY used for real-time instead of external pub/sub?
□ Are partial indexes used on filtered queries?
□ Is BRIN used on append-only timestamp columns?
□ Is connection pooling configured (PgBouncer in transaction mode)?
```

---

## EXTENSIONS REFERENCE

| Extension | Replaces | Install |
|---|---|---|
| `pg_trgm` | Algolia, Typesense | Built-in (enable only) |
| `tsvector` | Elasticsearch | Built-in (always available) |
| `pgvector` | Pinecone, Chroma, Weaviate | `CREATE EXTENSION vector` |
| `pg_cron` | Celery beat, APScheduler, n8n | Requires install |
| `PostGIS` | Google Maps API, geocoding SaaS | `CREATE EXTENSION postgis` |
| `pg_partman` | Custom partition management | Requires install |
| `unaccent` | Custom accent stripping | Built-in (enable only) |
| `uuid-ossp` | UUID generation service | Built-in (enable only) |
| `pg_stat_statements` | APM query analysis | Built-in (enable only) |

---

## JUSTIFIED EXCEPTIONS

PostgreSQL is NOT the right answer in these specific cases:

| Case | Justified external service | Required threshold |
|---|---|---|
| Real-time pub/sub > 100k msg/sec | Redis Streams, Kafka | *Measured* traffic, not estimated |
| OLAP on > 1TB, complex analytics | ClickHouse, BigQuery | Measured slow queries on PG |
| Email deliverability | SendGrid, Postmark | Always (IP reputation) |
| Video/audio streaming | CDN (Cloudflare, Fastly) | Always |
| Global edge caching < 10ms | Cloudflare KV, Deno Deploy | < 50ms acceptable → PG |
| ML model serving | Dedicated inference service | Always |

**The key word is *measured*. Most "we'll need it when we scale" decisions are made before a single user exists.**

---

*See `migrations/` for step-by-step migration guides from Redis, MongoDB, n8n, and Elasticsearch.*  
*See `patterns/` for advanced patterns: connection pooling, partitioning, observability.*  
*See `anti-patterns/` for the 10 most common PostgreSQL mistakes and how to fix them.*
