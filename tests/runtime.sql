\set ON_ERROR_STOP on

BEGIN;

CREATE TEMP TABLE entities (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  tenant_id uuid NOT NULL,
  kind text NOT NULL,
  data jsonb NOT NULL DEFAULT '{}'::jsonb
);
CREATE INDEX entities_data_gin ON entities USING gin (data);
INSERT INTO entities (tenant_id, kind, data)
VALUES ('00000000-0000-0000-0000-000000000001', 'invoice', '{"status":"paid","amount":120}');
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM entities
    WHERE kind = 'invoice' AND data @> '{"status":"paid"}'::jsonb
  ) THEN
    RAISE EXCEPTION 'JSONB containment pattern failed';
  END IF;
END $$;

CREATE TEMP TABLE job_queue (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  payload jsonb NOT NULL,
  status text NOT NULL DEFAULT 'pending' CHECK (status IN ('pending','processing','done','failed','retrying')),
  priority integer NOT NULL DEFAULT 0,
  attempts integer NOT NULL DEFAULT 0,
  run_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX job_queue_claim_idx ON job_queue (priority DESC, run_at, id)
WHERE status IN ('pending','retrying');
INSERT INTO job_queue (payload, priority) VALUES ('{"job":1}', 5), ('{"job":2}', 1);

WITH claimed AS (
  SELECT id
  FROM job_queue
  WHERE status IN ('pending','retrying') AND run_at <= now()
  ORDER BY priority DESC, run_at, id
  LIMIT 1
  FOR UPDATE SKIP LOCKED
)
UPDATE job_queue AS q
SET status = 'processing', attempts = attempts + 1
FROM claimed
WHERE q.id = claimed.id;

DO $$
DECLARE
  processing_count integer;
  pending_count integer;
BEGIN
  SELECT count(*) INTO processing_count FROM job_queue WHERE status = 'processing';
  SELECT count(*) INTO pending_count FROM job_queue WHERE status = 'pending';
  IF processing_count <> 1 OR pending_count <> 1 THEN
    RAISE EXCEPTION 'queue claim invariant failed: processing %, pending %', processing_count, pending_count;
  END IF;
END $$;

CREATE TEMP TABLE idempotency_events (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  idempotency_key text NOT NULL UNIQUE,
  payload jsonb NOT NULL
);
INSERT INTO idempotency_events (idempotency_key, payload)
VALUES ('evt-1', '{}') ON CONFLICT DO NOTHING;
INSERT INTO idempotency_events (idempotency_key, payload)
VALUES ('evt-1', '{"duplicate":true}') ON CONFLICT DO NOTHING;
DO $$
BEGIN
  IF (SELECT count(*) FROM idempotency_events WHERE idempotency_key = 'evt-1') <> 1 THEN
    RAISE EXCEPTION 'idempotency invariant failed';
  END IF;
END $$;

CREATE TEMP TABLE rate_limits (
  key text NOT NULL,
  window_start timestamptz NOT NULL,
  count integer NOT NULL DEFAULT 1,
  PRIMARY KEY (key, window_start)
);
INSERT INTO rate_limits (key, window_start, count)
VALUES ('user:1', date_trunc('minute', now()), 1)
ON CONFLICT (key, window_start) DO UPDATE SET count = rate_limits.count + 1;
INSERT INTO rate_limits (key, window_start, count)
VALUES ('user:1', date_trunc('minute', now()), 1)
ON CONFLICT (key, window_start) DO UPDATE SET count = rate_limits.count + 1;
DO $$
BEGIN
  IF (SELECT count FROM rate_limits WHERE key = 'user:1') <> 2 THEN
    RAISE EXCEPTION 'rate-limit atomic increment failed';
  END IF;
END $$;

CREATE TEMP TABLE documents (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  title text NOT NULL,
  body text NOT NULL,
  search_vec tsvector GENERATED ALWAYS AS (
    setweight(to_tsvector('english', coalesce(title,'')), 'A') ||
    setweight(to_tsvector('english', coalesce(body,'')), 'B')
  ) STORED
);
CREATE INDEX documents_fts_idx ON documents USING gin (search_vec);
INSERT INTO documents (title, body) VALUES ('PostgreSQL queue', 'Durable worker pattern with row locking');
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM documents WHERE search_vec @@ plainto_tsquery('english', 'durable queue')
  ) THEN
    RAISE EXCEPTION 'full-text search pattern failed';
  END IF;
END $$;

SELECT pg_advisory_xact_lock(424242);

ROLLBACK;

SELECT 'postgres-first runtime smoke: OK' AS result;
