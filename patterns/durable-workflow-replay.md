# Durable workflow replay and versioned runs

This pattern is for workflows that must survive worker crashes, retries, waits, and application deployments while PostgreSQL remains the durable source of truth.

It is **not** a claim that PostgreSQL automatically provides every feature of a dedicated workflow engine. Treat the design as `PARTIAL` until the target workload has exercised crash recovery, replay, external side effects, upgrade compatibility, and operational recovery.

## Invariants

1. **Pin a workflow specification version when the run is created.** A run started under `v1` does not silently become `v2` because new application code was deployed.
2. **Persist durable state before relying on a wake-up.** `LISTEN/NOTIFY`, polling hints, queues, and schedulers may wake workers; logged PostgreSQL rows remain authoritative.
3. **Replay from persisted facts, not from process memory.** Record the inputs or outputs needed to reproduce nondeterministic decisions.
4. **Do not duplicate recomputable data without a reason.** Deterministic values may be recomputed from durable inputs; external responses, timestamps used in decisions, random choices, model/provider outputs, approvals, and side-effect receipts normally need durable evidence.
5. **Give every externally retried effect a stable idempotency key.** A worker crash after the provider accepted an operation must not create a second payment, message, publication, or other side effect.
6. **Use leases for execution ownership, not permanent locks.** Ownership expires and can be taken over after a crash. Takeover must not delete or rewrite prior history.
7. **Separate business failure from persistence failure.** A terminal domain error may end a workflow. Failure to persist that terminal state is a transient infrastructure failure and must be retried or reconciled.
8. **Fail closed on unsupported old versions.** If the runtime can no longer execute a persisted `spec_version`, mark the run for migration/manual recovery rather than replaying it under the latest code implicitly.
9. **Compaction requires a replay proof.** Do not delete history merely to reduce storage. Snapshot/compact only when the retained state is sufficient to reconstruct the required semantics and audit evidence.

## Minimal relational shape

A production schema will vary, but the authority boundaries should be explicit:

```sql
CREATE TABLE workflow_runs (
  run_id uuid PRIMARY KEY,
  workflow_name text NOT NULL,
  spec_version text NOT NULL,
  status text NOT NULL
    CHECK (status IN ('pending','running','waiting','succeeded','failed','needs_migration')),
  input jsonb NOT NULL,
  lease_owner text,
  lease_expires_at timestamptz,
  next_wakeup_at timestamptz,
  started_at timestamptz NOT NULL DEFAULT now(),
  completed_at timestamptz
);

CREATE TABLE workflow_events (
  event_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  run_id uuid NOT NULL REFERENCES workflow_runs(run_id),
  event_type text NOT NULL,
  step_key text,
  payload jsonb NOT NULL DEFAULT '{}'::jsonb,
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX workflow_events_replay_idx
  ON workflow_events (run_id, event_id);

CREATE TABLE workflow_steps (
  run_id uuid NOT NULL REFERENCES workflow_runs(run_id),
  step_key text NOT NULL,
  spec_version text NOT NULL,
  status text NOT NULL
    CHECK (status IN ('pending','running','succeeded','failed')),
  attempt integer NOT NULL DEFAULT 0,
  output jsonb,
  terminal_error jsonb,
  updated_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (run_id, step_key)
);

CREATE TABLE workflow_outbox (
  outbox_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  run_id uuid NOT NULL REFERENCES workflow_runs(run_id),
  step_key text NOT NULL,
  effect_key text NOT NULL,
  payload jsonb NOT NULL,
  delivered_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (run_id, step_key, effect_key)
);
```

A dedicated event table is useful when replay/audit is required. If the workload only needs resumable jobs and current state, a smaller state-plus-outbox model may be enough. Do not build an event-sourcing system solely because the pattern exists.

## Leasing and crash takeover

Claim only work whose lease is absent or expired:

```sql
WITH candidate AS (
  SELECT run_id
  FROM workflow_runs
  WHERE status IN ('pending','running','waiting')
    AND (next_wakeup_at IS NULL OR next_wakeup_at <= now())
    AND (lease_expires_at IS NULL OR lease_expires_at < now())
  ORDER BY coalesce(next_wakeup_at, started_at), run_id
  LIMIT 1
  FOR UPDATE SKIP LOCKED
)
UPDATE workflow_runs AS r
SET status = 'running',
    lease_owner = $1,
    lease_expires_at = now() + $2::interval
FROM candidate
WHERE r.run_id = candidate.run_id
RETURNING r.*;
```

The lease duration is workload-specific. It must be long enough for normal heartbeat jitter but short enough to meet recovery objectives. Test worker termination at multiple points, including after an external side effect but before local completion is persisted.

## Version-safe replay

Persist `spec_version` at run creation and dispatch through an explicit compatibility boundary:

```text
load run
→ resolve executor(run.workflow_name, run.spec_version)
→ unsupported version? mark needs_migration and stop
→ load durable step/event state
→ recompute deterministic values
→ reuse persisted nondeterministic outputs/receipts
→ continue from the first incomplete step
```

Deployment code may support several active specification versions. Removing an old executor requires a migration/recovery plan for unfinished runs.

Do not infer a run's version from the currently deployed package version.

## External effects

For a step that sends money, messages, publications, webhooks, or other externally visible actions:

1. derive a stable `effect_key` from the run and logical step;
2. persist the intent/outbox row transactionally with local state;
3. send using a provider idempotency key when the provider supports one;
4. persist the provider receipt or response needed for reconciliation;
5. on retry, reconcile before creating a new effect.

Exactly-once delivery across PostgreSQL and an arbitrary external provider is not automatic. The practical target is usually **at-least-once execution with idempotent or reconcilable effects**.

## Replay storage discipline

Persist what changes replay semantics:

- user or system inputs that cannot be reconstructed safely;
- external API responses used by later decisions;
- model outputs used as authoritative workflow inputs;
- human approvals/rejections;
- generated random values when they affect later behavior;
- provider receipts and external identifiers;
- terminal errors and migration decisions.

Prefer recomputation for deterministic transformations when the source inputs and compatible code/specification are available. This reduces replay-log growth, but only after proving recomputation is stable enough for the use case.

## Terminal-state rule

A workflow is not complete merely because the worker reached a terminal branch in memory.

Persist the terminal state and required receipts in PostgreSQL. If that write fails because of a transient connection/storage error, retry/reconcile the write. Do not convert a persistence failure into a successful terminal outcome.

## Failure tests

Before classifying the pattern as production-fit, exercise at least:

- crash before a step starts;
- crash after local state mutation but before commit;
- crash after an external provider accepts an effect but before receipt persistence;
- duplicate delivery/retry of the same logical step;
- lease expiry and takeover by another worker;
- deployment while old-version runs are unfinished;
- unsupported historical `spec_version`;
- transient failure while persisting success/failure;
- outbox delivery retry;
- restore from backup and replay/reconciliation after restore.

Record the recovery objective and measured result. If these paths are not exercised, use `PARTIAL` or `NOT_PROVEN`.

## When to use a specialist

Keep or introduce a dedicated workflow engine when measured requirements demand semantics or operational isolation that are uneconomic to reproduce here, for example:

- very large orchestration graphs with complex fan-out/fan-in;
- long-lived version migration tooling as a first-class product requirement;
- high-scale cross-region execution;
- mature visual debugging/operations required by the team;
- workflow-specific retention/replay guarantees beyond the database operating model;
- independent failure domains that justify another control plane.

The decision boundary is evidence, not preference.
