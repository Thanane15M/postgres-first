\set ON_ERROR_STOP on

DROP SCHEMA IF EXISTS pf_temporal CASCADE;
CREATE SCHEMA pf_temporal;

CREATE TABLE pf_temporal.ledger (
  event_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  event_type text NOT NULL,
  actor text,
  action_name text,
  revision text,
  outcome text,
  request_event_id bigint REFERENCES pf_temporal.ledger(event_id),
  policy_version text,
  payload jsonb NOT NULL DEFAULT '{}'::jsonb,
  created_at timestamptz NOT NULL DEFAULT clock_timestamp()
);

CREATE TABLE pf_temporal.policy_versions (
  policy_version text PRIMARY KEY,
  activation_event_id bigint NOT NULL UNIQUE REFERENCES pf_temporal.ledger(event_id),
  rule jsonb NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE pf_temporal.active_policy_state (
  singleton boolean PRIMARY KEY DEFAULT true CHECK (singleton),
  policy_version text NOT NULL REFERENCES pf_temporal.policy_versions(policy_version),
  activation_event_id bigint NOT NULL,
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE UNIQUE INDEX pf_temporal_one_decision_per_request
  ON pf_temporal.ledger(request_event_id)
  WHERE event_type='AUTHZ_DECISION';

CREATE OR REPLACE FUNCTION pf_temporal.lock_ledger()
RETURNS void
LANGUAGE sql
AS $$
  SELECT pg_advisory_xact_lock(hashtextextended('postgres-first:temporal-auth-ledger',0));
$$;

CREATE OR REPLACE FUNCTION pf_temporal.activate_policy(p_version text, p_rule jsonb)
RETURNS bigint
LANGUAGE plpgsql
AS $$
DECLARE
  v_event bigint;
BEGIN
  PERFORM pf_temporal.lock_ledger();

  INSERT INTO pf_temporal.ledger(event_type,actor,policy_version,payload)
  VALUES ('POLICY_ACTIVATED','policy-control-plane',p_version,p_rule)
  RETURNING event_id INTO v_event;

  INSERT INTO pf_temporal.policy_versions(policy_version,activation_event_id,rule)
  VALUES (p_version,v_event,p_rule);

  INSERT INTO pf_temporal.active_policy_state(singleton,policy_version,activation_event_id)
  VALUES (true,p_version,v_event)
  ON CONFLICT (singleton) DO UPDATE
  SET policy_version=EXCLUDED.policy_version,
      activation_event_id=EXCLUDED.activation_event_id,
      updated_at=now();

  RETURN v_event;
END;
$$;

CREATE OR REPLACE FUNCTION pf_temporal.record_fact(
  p_actor text,
  p_type text,
  p_revision text,
  p_outcome text
) RETURNS bigint
LANGUAGE plpgsql
AS $$
DECLARE
  v_event bigint;
BEGIN
  PERFORM pf_temporal.lock_ledger();
  INSERT INTO pf_temporal.ledger(event_type,actor,revision,outcome)
  VALUES (p_type,p_actor,p_revision,p_outcome)
  RETURNING event_id INTO v_event;
  RETURN v_event;
END;
$$;

CREATE OR REPLACE FUNCTION pf_temporal.record_action_request(
  p_actor text,
  p_action text,
  p_revision text
) RETURNS bigint
LANGUAGE plpgsql
AS $$
DECLARE
  v_event bigint;
BEGIN
  PERFORM pf_temporal.lock_ledger();
  INSERT INTO pf_temporal.ledger(event_type,actor,action_name,revision)
  VALUES ('ACTION_REQUEST',p_actor,p_action,p_revision)
  RETURNING event_id INTO v_event;
  RETURN v_event;
END;
$$;

CREATE OR REPLACE FUNCTION pf_temporal.evaluate_action_request(p_request bigint)
RETURNS TABLE(decision_event_id bigint, allowed boolean, policy_version text)
LANGUAGE plpgsql
AS $$
DECLARE
  req pf_temporal.ledger%ROWTYPE;
  existing pf_temporal.ledger%ROWTYPE;
  policy pf_temporal.policy_versions%ROWTYPE;
  tests_outcome text;
  scan_outcome text;
  verdict boolean := false;
  v_decision bigint;
BEGIN
  PERFORM pf_temporal.lock_ledger();

  SELECT * INTO existing
  FROM pf_temporal.ledger
  WHERE event_type='AUTHZ_DECISION'
    AND request_event_id=p_request;

  IF FOUND THEN
    decision_event_id := existing.event_id;
    allowed := (existing.outcome='ALLOW');
    policy_version := existing.policy_version;
    RETURN NEXT;
    RETURN;
  END IF;

  SELECT * INTO req
  FROM pf_temporal.ledger
  WHERE event_id=p_request
    AND event_type='ACTION_REQUEST'
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'action request % not found', p_request;
  END IF;

  SELECT * INTO policy
  FROM pf_temporal.policy_versions
  WHERE activation_event_id <= req.event_id
  ORDER BY activation_event_id DESC
  LIMIT 1;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'no policy active for request %', p_request;
  END IF;

  IF req.action_name='git_push' THEN
    SELECT outcome INTO tests_outcome
    FROM pf_temporal.ledger
    WHERE event_type='TESTS'
      AND revision=req.revision
      AND event_id < req.event_id
    ORDER BY event_id DESC
    LIMIT 1;

    SELECT outcome INTO scan_outcome
    FROM pf_temporal.ledger
    WHERE event_type='SECURITY_SCAN'
      AND revision=req.revision
      AND event_id < req.event_id
    ORDER BY event_id DESC
    LIMIT 1;

    verdict := (tests_outcome='pass' AND scan_outcome='pass');
  END IF;

  INSERT INTO pf_temporal.ledger(
    event_type,actor,action_name,revision,outcome,
    request_event_id,policy_version,payload
  ) VALUES (
    'AUTHZ_DECISION','policy-engine',req.action_name,req.revision,
    CASE WHEN verdict THEN 'ALLOW' ELSE 'DENY' END,
    req.event_id,policy.policy_version,
    jsonb_build_object(
      'tests_outcome',tests_outcome,
      'security_scan_outcome',scan_outcome
    )
  )
  RETURNING event_id INTO v_decision;

  decision_event_id := v_decision;
  allowed := verdict;
  policy_version := policy.policy_version;
  RETURN NEXT;
END;
$$;

SELECT pf_temporal.activate_policy(
  'v1',
  '{"git_push":{"requires":["latest_tests_pass","latest_security_scan_pass"]}}'::jsonb
);
SELECT pf_temporal.record_fact('ci','TESTS','rev-1','pass');
SELECT pf_temporal.record_fact('scanner','SECURITY_SCAN','rev-1','pass');

-- Two independent clients append requests concurrently. The advisory transaction
-- lock is the linearization point.
\! bash -c 'psql "$DATABASE_URL" -Atq -v ON_ERROR_STOP=1 -c "SELECT pf_temporal.record_action_request(\$\$agent-a\$\$,\$\$git_push\$\$,\$\$rev-1\$\$);" >/tmp/pf-temporal-a & p1=$!; psql "$DATABASE_URL" -Atq -v ON_ERROR_STOP=1 -c "SELECT pf_temporal.record_action_request(\$\$agent-b\$\$,\$\$git_push\$\$,\$\$rev-1\$\$);" >/tmp/pf-temporal-b & p2=$!; wait "$p1"; wait "$p2"'

SELECT event_id AS req_a
FROM pf_temporal.ledger
WHERE event_type='ACTION_REQUEST' AND actor='agent-a'
ORDER BY event_id DESC LIMIT 1 \gset

SELECT event_id AS req_b
FROM pf_temporal.ledger
WHERE event_type='ACTION_REQUEST' AND actor='agent-b'
ORDER BY event_id DESC LIMIT 1 \gset

SELECT :req_a::bigint <> :req_b::bigint AS distinct_requests \gset
\if :distinct_requests
\else
  \echo 'concurrent requests did not receive distinct ledger events'
  \quit 1
\endif

-- Evaluate both requests concurrently. There must be one decision per request.
\! bash -c 'psql "$DATABASE_URL" -Atq -v ON_ERROR_STOP=1 -c "SELECT allowed FROM pf_temporal.evaluate_action_request((SELECT event_id FROM pf_temporal.ledger WHERE event_type=\$\$ACTION_REQUEST\$\$ AND actor=\$\$agent-a\$\$ ORDER BY event_id DESC LIMIT 1));" >/tmp/pf-temporal-da & p1=$!; psql "$DATABASE_URL" -Atq -v ON_ERROR_STOP=1 -c "SELECT allowed FROM pf_temporal.evaluate_action_request((SELECT event_id FROM pf_temporal.ledger WHERE event_type=\$\$ACTION_REQUEST\$\$ AND actor=\$\$agent-b\$\$ ORDER BY event_id DESC LIMIT 1));" >/tmp/pf-temporal-db & p2=$!; wait "$p1"; wait "$p2"'

SELECT count(*)=2 AS two_allowed_decisions
FROM pf_temporal.ledger
WHERE event_type='AUTHZ_DECISION'
  AND outcome='ALLOW'
  AND request_event_id IN (:req_a,:req_b) \gset
\if :two_allowed_decisions
\else
  \echo 'eligible concurrent requests were not both allowed'
  \quit 1
\endif

-- Re-evaluation is idempotent.
SELECT allowed FROM pf_temporal.evaluate_action_request(:req_a);
SELECT count(*)=1 AS still_one_decision
FROM pf_temporal.ledger
WHERE event_type='AUTHZ_DECISION'
  AND request_event_id=:req_a \gset
\if :still_one_decision
\else
  \echo 're-evaluation created a duplicate authorization decision'
  \quit 1
\endif

-- Crash boundary: commit request, stop before decision, then activate v2.
SELECT pf_temporal.record_action_request(
  'agent-crash','git_push','rev-1'
) AS crash_req \gset

SELECT pf_temporal.activate_policy(
  'v2',
  '{"git_push":{"requires":["latest_tests_pass","latest_security_scan_pass"],"note":"new-version"}}'::jsonb
);

SELECT policy_version='v1' AS request_keeps_original_policy
FROM pf_temporal.evaluate_action_request(:crash_req) \gset
\if :request_keeps_original_policy
\else
  \echo 'delayed evaluation used a policy activated after the request'
  \quit 1
\endif

SELECT policy_version='v2' AS projection_is_v2
FROM pf_temporal.active_policy_state
WHERE singleton \gset
\if :projection_is_v2
\else
  \echo 'derived current policy projection did not advance'
  \quit 1
\endif

-- Later failed evidence invalidates later requests.
SELECT pf_temporal.record_fact('ci','TESTS','rev-1','fail');
SELECT pf_temporal.record_action_request(
  'agent-c','git_push','rev-1'
) AS deny_req \gset

SELECT NOT allowed AS later_failure_denies
FROM pf_temporal.evaluate_action_request(:deny_req) \gset
\if :later_failure_denies
\else
  \echo 'later failed tests did not deny later git_push'
  \quit 1
\endif

SELECT count(*)=0 AS no_orphan_decisions
FROM pf_temporal.ledger d
LEFT JOIN pf_temporal.ledger r ON r.event_id=d.request_event_id
WHERE d.event_type='AUTHZ_DECISION'
  AND (r.event_id IS NULL OR r.event_type <> 'ACTION_REQUEST') \gset
\if :no_orphan_decisions
\else
  \echo 'authorization ledger contains orphan decisions'
  \quit 1
\endif

DROP SCHEMA pf_temporal CASCADE;
SELECT 'temporal authorization: OK' AS result;
