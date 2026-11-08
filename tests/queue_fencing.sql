\set ON_ERROR_STOP on

BEGIN;

CREATE TEMP TABLE business_rows (
  id bigint PRIMARY KEY,
  payload text NOT NULL
);

CREATE TEMP TABLE fenced_jobs (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  business_id bigint NOT NULL,
  status text NOT NULL DEFAULT 'pending' CHECK (status IN ('pending','processing','done')),
  lease_token bigint NOT NULL DEFAULT 0,
  lease_expires_at timestamptz
);

-- Transactional enqueue: rollback removes both business state and job intent.
SAVEPOINT rollback_case;
INSERT INTO business_rows (id, payload) VALUES (1, 'rollback');
INSERT INTO fenced_jobs (business_id) VALUES (1);
ROLLBACK TO SAVEPOINT rollback_case;

DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM business_rows WHERE id = 1)
     OR EXISTS (SELECT 1 FROM fenced_jobs WHERE business_id = 1) THEN
    RAISE EXCEPTION 'transactional enqueue rollback invariant failed';
  END IF;
END $$;

-- Transactional enqueue: commit both rows, then recheck in a new transaction.
INSERT INTO business_rows (id, payload) VALUES (2, 'commit');
INSERT INTO fenced_jobs (business_id) VALUES (2);
COMMIT;
BEGIN;

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM business_rows WHERE id = 2)
     OR NOT EXISTS (SELECT 1 FROM fenced_jobs WHERE business_id = 2) THEN
    RAISE EXCEPTION 'transactional enqueue commit invariant failed';
  END IF;
END $$;

-- Worker A claims token 1.
UPDATE fenced_jobs
SET status = 'processing',
    lease_token = lease_token + 1,
    lease_expires_at = now() - interval '1 second'
WHERE business_id = 2
RETURNING lease_token;

-- Worker B reclaims after expiry and receives token 2.
UPDATE fenced_jobs
SET lease_token = lease_token + 1,
    lease_expires_at = now() + interval '5 minutes'
WHERE business_id = 2
  AND status = 'processing'
  AND lease_expires_at < now()
RETURNING lease_token;

-- A stale completion with token 1 must update zero rows.
WITH stale AS (
  UPDATE fenced_jobs
  SET status = 'done'
  WHERE business_id = 2
    AND status = 'processing'
    AND lease_token = 1
  RETURNING 1
)
SELECT CASE WHEN count(*) = 0 THEN 1 ELSE CAST('stale worker completion accepted' AS integer) END
FROM stale;

-- Current worker B with token 2 may complete.
UPDATE fenced_jobs
SET status = 'done'
WHERE business_id = 2
  AND status = 'processing'
  AND lease_token = 2;

DO $$
BEGIN
  IF (SELECT status FROM fenced_jobs WHERE business_id = 2) <> 'done'
     OR (SELECT lease_token FROM fenced_jobs WHERE business_id = 2) <> 2 THEN
    RAISE EXCEPTION 'current worker fencing completion invariant failed';
  END IF;
END $$;

ROLLBACK;

SELECT 'transactional enqueue + stale-worker fencing: OK' AS result;
