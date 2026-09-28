\set ON_ERROR_STOP on

BEGIN;

CREATE TEMP TABLE workflow_runs (
  run_id text PRIMARY KEY,
  workflow_name text NOT NULL,
  spec_version text NOT NULL,
  status text NOT NULL
    CHECK (status IN ('pending','running','waiting','succeeded','failed','needs_migration')),
  lease_owner text,
  lease_expires_at timestamptz,
  next_wakeup_at timestamptz
);

CREATE TEMP TABLE workflow_steps (
  run_id text NOT NULL REFERENCES workflow_runs(run_id),
  step_key text NOT NULL,
  spec_version text NOT NULL,
  status text NOT NULL CHECK (status IN ('pending','running','succeeded','failed')),
  output jsonb,
  PRIMARY KEY (run_id, step_key)
);

CREATE TEMP TABLE workflow_events (
  event_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  run_id text NOT NULL REFERENCES workflow_runs(run_id),
  event_type text NOT NULL,
  step_key text,
  payload jsonb NOT NULL DEFAULT '{}'::jsonb
);

CREATE TEMP TABLE workflow_outbox (
  outbox_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  run_id text NOT NULL REFERENCES workflow_runs(run_id),
  step_key text NOT NULL,
  effect_key text NOT NULL,
  payload jsonb NOT NULL,
  delivered_at timestamptz,
  UNIQUE (run_id, step_key, effect_key)
);

INSERT INTO workflow_runs (
  run_id, workflow_name, spec_version, status, lease_owner, lease_expires_at, next_wakeup_at
)
VALUES (
  'run-1', 'publish-content', 'v1', 'running', 'worker-a', now() - interval '1 minute', now()
);

DO $$
BEGIN
  IF (SELECT spec_version FROM workflow_runs WHERE run_id = 'run-1') <> 'v1' THEN
    RAISE EXCEPTION 'workflow specification version drifted';
  END IF;
END $$;

UPDATE workflow_runs
SET lease_owner = 'worker-b',
    lease_expires_at = now() + interval '5 minutes'
WHERE run_id = 'run-1'
  AND lease_expires_at < now();

DO $$
BEGIN
  IF (SELECT lease_owner FROM workflow_runs WHERE run_id = 'run-1') <> 'worker-b' THEN
    RAISE EXCEPTION 'expired lease was not taken over';
  END IF;
  IF (SELECT spec_version FROM workflow_runs WHERE run_id = 'run-1') <> 'v1' THEN
    RAISE EXCEPTION 'lease takeover changed spec_version';
  END IF;
END $$;

INSERT INTO workflow_steps (run_id, step_key, spec_version, status, output)
VALUES ('run-1', 'render', 'v1', 'succeeded', '{"asset":"asset-123"}')
ON CONFLICT (run_id, step_key) DO NOTHING;

INSERT INTO workflow_steps (run_id, step_key, spec_version, status, output)
VALUES ('run-1', 'render', 'v1', 'succeeded', '{"asset":"duplicate"}')
ON CONFLICT (run_id, step_key) DO NOTHING;

DO $$
BEGIN
  IF (SELECT count(*) FROM workflow_steps WHERE run_id = 'run-1' AND step_key = 'render') <> 1 THEN
    RAISE EXCEPTION 'step idempotency invariant failed';
  END IF;
  IF (SELECT output->>'asset' FROM workflow_steps WHERE run_id = 'run-1' AND step_key = 'render') <> 'asset-123' THEN
    RAISE EXCEPTION 'duplicate retry overwrote durable step output';
  END IF;
END $$;

INSERT INTO workflow_outbox (run_id, step_key, effect_key, payload)
VALUES ('run-1', 'publish', 'linkedin:post:run-1', '{"body":"hello"}')
ON CONFLICT (run_id, step_key, effect_key) DO NOTHING;

INSERT INTO workflow_outbox (run_id, step_key, effect_key, payload)
VALUES ('run-1', 'publish', 'linkedin:post:run-1', '{"body":"duplicate"}')
ON CONFLICT (run_id, step_key, effect_key) DO NOTHING;

DO $$
BEGIN
  IF (SELECT count(*) FROM workflow_outbox WHERE effect_key = 'linkedin:post:run-1') <> 1 THEN
    RAISE EXCEPTION 'outbox effect idempotency invariant failed';
  END IF;
END $$;

INSERT INTO workflow_events (run_id, event_type, step_key, payload)
VALUES
  ('run-1', 'step.succeeded', 'render', '{"asset":"asset-123"}'),
  ('run-1', 'effect.enqueued', 'publish', '{"effect_key":"linkedin:post:run-1"}');

DO $$
DECLARE
  first_event bigint;
  second_event bigint;
BEGIN
  SELECT min(event_id), max(event_id)
  INTO first_event, second_event
  FROM workflow_events
  WHERE run_id = 'run-1';

  IF first_event IS NULL OR second_event IS NULL OR first_event >= second_event THEN
    RAISE EXCEPTION 'event replay ordering invariant failed';
  END IF;
END $$;

UPDATE workflow_runs
SET status = 'succeeded',
    lease_owner = NULL,
    lease_expires_at = NULL
WHERE run_id = 'run-1' AND status <> 'succeeded';

UPDATE workflow_runs
SET status = 'succeeded',
    lease_owner = NULL,
    lease_expires_at = NULL
WHERE run_id = 'run-1' AND status <> 'succeeded';

DO $$
BEGIN
  IF (SELECT status FROM workflow_runs WHERE run_id = 'run-1') <> 'succeeded' THEN
    RAISE EXCEPTION 'terminal state persistence failed';
  END IF;
  IF (SELECT count(*) FROM workflow_runs WHERE run_id = 'run-1') <> 1 THEN
    RAISE EXCEPTION 'terminal retry duplicated workflow run';
  END IF;
END $$;

ROLLBACK;

SELECT 'postgres-first durable workflow replay smoke: OK' AS result;
