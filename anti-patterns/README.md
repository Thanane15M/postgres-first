# PostgreSQL Anti-Patterns: The 10 Most Expensive Mistakes

These patterns appear in production codebases constantly. Each one has a fix.

---

## 1. SELECT * In Application Code

```sql
-- ❌ NEVER
SELECT * FROM users WHERE id = $1;
-- Fetches 40+ columns. Breaks when schema changes. Prevents index-only scans.

-- ✅ ALWAYS name your columns
SELECT id, email, name, created_at FROM users WHERE id = $1;
```

---

## 2. N+1 Queries (The Performance Killer)

```python
# ❌ NEVER — 1 query for list + 1 per item = N+1
users = db.query("SELECT id FROM users LIMIT 100")
for user in users:
    orders = db.query("SELECT * FROM orders WHERE user_id = $1", user.id)

# ✅ ONE query with JOIN or lateral
db.query("""
    SELECT u.id, u.email,
           json_agg(json_build_object('id', o.id, 'amount', o.amount)) AS orders
    FROM users u
    LEFT JOIN orders o ON o.user_id = u.id
    WHERE u.id = ANY($1)
    GROUP BY u.id, u.email
""", user_ids)
```

---

## 3. Missing Index on Foreign Keys

```sql
-- ❌ Unindexed FK = full table scan on every JOIN
CREATE TABLE orders (
  user_id BIGINT REFERENCES users(id)  -- no index!
);

-- ✅ Index every FK column
CREATE INDEX idx_orders_user_id ON orders (user_id);
CREATE INDEX idx_invoices_order_id ON invoices (order_id);
CREATE INDEX idx_events_entity ON events (entity_type, entity_id);
```

---

## 4. LIKE '%term%' Without pg_trgm

```sql
-- ❌ Full table scan, cannot use any index
SELECT * FROM products WHERE name LIKE '%coffee%';

-- ✅ pg_trgm GIN index makes this instant
CREATE EXTENSION pg_trgm;
CREATE INDEX idx_products_name_trgm ON products USING GIN (name gin_trgm_ops);
SELECT * FROM products WHERE name ILIKE '%coffee%';  -- now uses index
```

---

## 5. Using VARCHAR(255) Everywhere

```sql
-- ❌ VARCHAR(255) is cargo-cult from MySQL. No benefit in PostgreSQL.
CREATE TABLE users (
  name VARCHAR(255),  -- arbitrary limit with no performance benefit
  bio  VARCHAR(255)   -- truncates real data silently
);

-- ✅ Use TEXT. Add CHECK constraint if you actually need a limit.
CREATE TABLE users (
  name TEXT NOT NULL CHECK (length(name) BETWEEN 1 AND 200),
  bio  TEXT
);
```

---

## 6. TIMESTAMP Without Timezone

```sql
-- ❌ TIMESTAMP stores local time — wrong across DST and deployments in different zones
created_at TIMESTAMP DEFAULT NOW()

-- ✅ TIMESTAMPTZ stores UTC, displays in any timezone correctly
created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
```

---

## 7. Transactions Held Open Across Network Calls

```python
# ❌ Transaction stays open during API call — blocks vacuuum, holds locks
async with conn.transaction():
    user = await conn.fetchrow("SELECT * FROM users WHERE id = $1", user_id)
    response = await httpx.get(f"https://api.external.com/verify/{user['email']}")  # DANGER
    await conn.execute("UPDATE users SET verified = true WHERE id = $1", user_id)

# ✅ Do external I/O outside the transaction
user = await conn.fetchrow("SELECT * FROM users WHERE id = $1", user_id)
response = await httpx.get(f"https://api.external.com/verify/{user['email']}")  # outside tx
async with conn.transaction():
    await conn.execute("UPDATE users SET verified = true WHERE id = $1", user_id)
```

---

## 8. Soft Delete With `is_deleted = true` (No Partial Index)

```sql
-- ❌ Every query must filter soft-deleted rows. Index bloat. Complexity everywhere.
SELECT * FROM orders WHERE user_id = $1 AND is_deleted = false;

-- ✅ Partial index: only live rows are indexed
CREATE INDEX idx_orders_live ON orders (user_id, created_at DESC)
  WHERE deleted_at IS NULL;

-- Query automatically uses this index
SELECT * FROM orders WHERE user_id = $1 AND deleted_at IS NULL;
-- Deleted rows are invisible to this index = smaller, faster
```

---

## 9. SERIAL Instead of BIGSERIAL or gen_random_uuid()

```sql
-- ❌ SERIAL = 32-bit integer. Runs out at 2.1 billion rows. Exposes row count.
id SERIAL PRIMARY KEY

-- ✅ BIGSERIAL for ordered, high-volume tables
id BIGSERIAL PRIMARY KEY  -- 9.2 × 10^18 max

-- ✅ UUID v7 for distributed systems, public APIs (doesn't expose sequence)
id UUID PRIMARY KEY DEFAULT gen_random_uuid()

-- ✅ Or UUIDv7 (time-ordered, better for indexes than v4)
-- Available in PG 17+ natively, or use extension
```

---

## 10. Not Using `EXPLAIN ANALYZE` Before Deploying

```sql
-- Run this before every query that touches > 10k rows
EXPLAIN (ANALYZE, BUFFERS, FORMAT TEXT)
SELECT u.id, COUNT(o.id) AS order_count
FROM users u
LEFT JOIN orders o ON o.user_id = u.id
WHERE u.created_at > NOW() - INTERVAL '30 days'
GROUP BY u.id;

-- Red flags to look for:
-- "Seq Scan" on large table → missing index
-- "rows=10000000 (actual rows=1)" → stale statistics → run ANALYZE
-- "Nested Loop" on large tables → missing index on the inner table
-- "Hash Batches=8" → work_mem too low → SET work_mem = '256MB'
-- Actual time >> Estimated time → stale statistics or missing index
```

```sql
-- Keep statistics fresh (run after bulk loads)
ANALYZE users;
ANALYZE orders;

-- For tables updated frequently, increase statistics target
ALTER TABLE orders ALTER COLUMN status SET STATISTICS 500;
ANALYZE orders;
```
