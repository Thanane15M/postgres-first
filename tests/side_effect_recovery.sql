\set ON_ERROR_STOP on

DROP SCHEMA IF EXISTS pf_effect_recovery CASCADE;
CREATE SCHEMA pf_effect_recovery;

CREATE TABLE pf_effect_recovery.effect_intents (
  effect_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  run_id text NOT NULL,
  effect_key text NOT NULL,
  replay_class text NOT NULL CHECK (replay_class IN (
    'REPLAY_SAFE','IDEMPOTENT_WITH_KEY','NON_REPLAYABLE','UNKNOWN_SIDE_EFFECT'
  )),
  idempotency_key text,
  request jsonb NOT NULL,
  state text NOT NULL DEFAULT 'intent_committed' CHECK (state IN (
    'intent_committed','executing','completed','interrupted','reconciliation_required'
  )),
  execution_attempts integer NOT NULL DEFAULT 0 CHECK (execution_attempts >= 0),
  partial_output jsonb,
  result jsonb,
  UNIQUE (run_id, effect_key),
  CHECK (replay_class <> 'IDEMPOTENT_WITH_KEY' OR idempotency_key IS NOT NULL)
);

CREATE OR REPLACE FUNCTION pf_effect_recovery.register_effect(
  p_run_id text,
  p_effect_key text,
  p_replay_class text,
  p_idempotency_key text,
  p_request jsonb
) RETURNS pf_effect_recovery.effect_intents
LANGUAGE plpgsql
AS $$
DECLARE
  v pf_effect_recovery.effect_intents%ROWTYPE;
BEGIN
  SELECT * INTO v
  FROM pf_effect_recovery.effect_intents
  WHERE run_id = p_run_id AND effect_key = p_effect_key
  FOR UPDATE;

  IF FOUND THEN
    IF v.replay_class <> p_replay_class
       OR v.idempotency_key IS DISTINCT FROM p_idempotency_key
       OR v.request <> p_request THEN
      RAISE EXCEPTION 'same effect key reused with different durable intent'
        USING ERRCODE = '22000';
    END IF;
    RETURN v;
  END IF;

  INSERT INTO pf_effect_recovery.effect_intents(
    run_id, effect_key, replay_class, idempotency_key, request
  ) VALUES (
    p_run_id, p_effect_key, p_replay_class, p_idempotency_key, p_request
  )
  RETURNING * INTO v;
  RETURN v;
END;
$$;

CREATE OR REPLACE FUNCTION pf_effect_recovery.begin_execution(p_effect_id bigint)
RETURNS pf_effect_recovery.effect_intents
LANGUAGE plpgsql
AS $$
DECLARE
  v pf_effect_recovery.effect_intents%ROWTYPE;
BEGIN
  UPDATE pf_effect_recovery.effect_intents
  SET state = 'executing',
      execution_attempts = execution_attempts + 1
  WHERE effect_id = p_effect_id
    AND state = 'intent_committed'
  RETURNING * INTO v;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'effect % is not executable from its current state', p_effect_id
      USING ERRCODE = '55000';
  END IF;
  RETURN v;
END;
$$;

CREATE OR REPLACE FUNCTION pf_effect_recovery.recover_after_crash(p_effect_id bigint)
RETURNS text
LANGUAGE plpgsql
AS $$
DECLARE
  v pf_effect_recovery.effect_intents%ROWTYPE;
  decision text;
BEGIN
  SELECT * INTO v
  FROM pf_effect_recovery.effect_intents
  WHERE effect_id = p_effect_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'effect % not found', p_effect_id;
  END IF;

  IF v.state = 'completed' THEN
    RETURN 'ALREADY_COMPLETED';
  END IF;

  IF v.state <> 'executing' THEN
    RAISE EXCEPTION 'effect % is not at a crash boundary', p_effect_id
      USING ERRCODE = '55000';
  END IF;

  CASE v.replay_class
    WHEN 'REPLAY_SAFE' THEN
      UPDATE pf_effect_recovery.effect_intents SET state='intent_committed' WHERE effect_id=p_effect_id;
      decision := 'REPLAY_ALLOWED';
    WHEN 'IDEMPOTENT_WITH_KEY' THEN
      UPDATE pf_effect_recovery.effect_intents SET state='intent_committed' WHERE effect_id=p_effect_id;
      decision := 'RETRY_WITH_SAME_KEY';
    WHEN 'NON_REPLAYABLE' THEN
      UPDATE pf_effect_recovery.effect_intents SET state='interrupted' WHERE effect_id=p_effect_id;
      decision := 'INTERRUPTED';
    WHEN 'UNKNOWN_SIDE_EFFECT' THEN
      UPDATE pf_effect_recovery.effect_intents SET state='reconciliation_required' WHERE effect_id=p_effect_id;
      decision := 'RECONCILIATION_REQUIRED';
  END CASE;

  RETURN decision;
END;
$$;

-- Payload-aware idempotency: same intent returns the same row.
SELECT (pf_effect_recovery.register_effect(
  'run-1','notify','REPLAY_SAFE',NULL,'{"to":"a"}'::jsonb
)).effect_id AS safe_id \gset
SELECT (pf_effect_recovery.register_effect(
  'run-1','notify','REPLAY_SAFE',NULL,'{"to":"a"}'::jsonb
)).effect_id AS safe_id_again \gset
SELECT :safe_id::bigint = :safe_id_again::bigint AS same_id \gset
\if :same_id
\else
  \echo 'same durable intent did not return the original effect'
  \quit 1
\endif

-- Same logical key with a different payload is a conflict.
DO $$
BEGIN
  BEGIN
    PERFORM pf_effect_recovery.register_effect(
      'run-1','notify','REPLAY_SAFE',NULL,'{"to":"different"}'::jsonb
    );
    RAISE EXCEPTION 'expected payload conflict was not raised';
  EXCEPTION WHEN SQLSTATE '22000' THEN
    NULL;
  END;
END;
$$;

-- Replay-safe work may be retried.
SELECT (pf_effect_recovery.begin_execution(:safe_id)).execution_attempts = 1 AS first_attempt \gset
SELECT pf_effect_recovery.recover_after_crash(:safe_id) = 'REPLAY_ALLOWED' AS safe_replay \gset
SELECT (pf_effect_recovery.begin_execution(:safe_id)).execution_attempts = 2 AS second_attempt \gset
\if :safe_replay
\else
  \echo 'replay-safe effect was not made eligible for explicit replay'
  \quit 1
\endif
\if :second_attempt
\else
  \echo 'replay-safe effect did not record the second execution'
  \quit 1
\endif

UPDATE pf_effect_recovery.effect_intents
SET state='completed', result='{"receipt":"ok"}'::jsonb
WHERE effect_id=:safe_id;
SELECT pf_effect_recovery.recover_after_crash(:safe_id) = 'ALREADY_COMPLETED' AS terminal_stays_terminal \gset
\if :terminal_stays_terminal
\else
  \echo 'completed effect regressed during recovery'
  \quit 1
\endif

-- Idempotent-with-key retry keeps the exact same key.
SELECT (pf_effect_recovery.register_effect(
  'run-2','charge','IDEMPOTENT_WITH_KEY','charge:run-2:1','{"amount":42}'::jsonb
)).effect_id AS idem_id \gset
SELECT (pf_effect_recovery.begin_execution(:idem_id)).effect_id > 0 AS idem_started \gset
SELECT pf_effect_recovery.recover_after_crash(:idem_id) = 'RETRY_WITH_SAME_KEY' AS idem_recovery \gset
SELECT idempotency_key = 'charge:run-2:1' AS idem_key_stable
FROM pf_effect_recovery.effect_intents WHERE effect_id=:idem_id \gset
\if :idem_recovery
\else
  \echo 'idempotent effect was not classified for same-key retry'
  \quit 1
\endif
\if :idem_key_stable
\else
  \echo 'idempotency key changed across recovery'
  \quit 1
\endif

-- Non-replayable work stops after an uncertain crash boundary.
SELECT (pf_effect_recovery.register_effect(
  'run-3','publish','NON_REPLAYABLE',NULL,'{"post":"x"}'::jsonb
)).effect_id AS nonreplay_id \gset
SELECT (pf_effect_recovery.begin_execution(:nonreplay_id)).effect_id > 0 AS nonreplay_started \gset
UPDATE pf_effect_recovery.effect_intents
SET partial_output='{"provider_request_id":"req-17"}'::jsonb
WHERE effect_id=:nonreplay_id;
SELECT pf_effect_recovery.recover_after_crash(:nonreplay_id) = 'INTERRUPTED' AS interrupted \gset
\if :interrupted
\else
  \echo 'non-replayable effect was not interrupted'
  \quit 1
\endif

DO $$
BEGIN
  BEGIN
    PERFORM pf_effect_recovery.begin_execution(:nonreplay_id);
    RAISE EXCEPTION 'non-replayable effect executed twice';
  EXCEPTION WHEN SQLSTATE '55000' THEN
    NULL;
  END;
END;
$$;

SELECT execution_attempts=1
   AND state='interrupted'
   AND partial_output='{"provider_request_id":"req-17"}'::jsonb AS nonreplay_preserved
FROM pf_effect_recovery.effect_intents WHERE effect_id=:nonreplay_id \gset
\if :nonreplay_preserved
\else
  \echo 'non-replayable crash state was not preserved'
  \quit 1
\endif

-- Unknown remote outcome requires reconciliation.
SELECT (pf_effect_recovery.register_effect(
  'run-4','transfer','UNKNOWN_SIDE_EFFECT',NULL,'{"amount":9}'::jsonb
)).effect_id AS unknown_id \gset
SELECT (pf_effect_recovery.begin_execution(:unknown_id)).effect_id > 0 AS unknown_started \gset
SELECT pf_effect_recovery.recover_after_crash(:unknown_id) = 'RECONCILIATION_REQUIRED' AS unknown_reconcile \gset
SELECT state='reconciliation_required' AND execution_attempts=1 AS unknown_closed
FROM pf_effect_recovery.effect_intents WHERE effect_id=:unknown_id \gset
\if :unknown_reconcile
\else
  \echo 'unknown side effect did not require reconciliation'
  \quit 1
\endif
\if :unknown_closed
\else
  \echo 'unknown side effect became executable again'
  \quit 1
\endif

DROP SCHEMA pf_effect_recovery CASCADE;
SELECT 'durable side-effect recovery: OK' AS result;
