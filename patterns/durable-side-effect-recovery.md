# Durable side-effect recovery

Use this pattern when a workflow can crash between committing an intent and learning whether an external side effect completed.

The central rule is:

> durable workflow replay does not imply that every unfinished external operation is safe to run again.

## Replay classes

Classify every externally visible operation before execution:

- `REPLAY_SAFE` — repeating the operation is semantically harmless for the target system.
- `IDEMPOTENT_WITH_KEY` — repeating is allowed only with the exact same stable provider/application idempotency key.
- `NON_REPLAYABLE` — after an uncertain crash boundary, do not execute again automatically.
- `UNKNOWN_SIDE_EFFECT` — the remote outcome is unknown and must be reconciled before another mutation.

Default to the most restrictive class that matches the real provider contract. A local HTTP retry flag is not evidence that the remote mutation is idempotent.

## State machine

Persist intent before execution:

    INTENT_COMMITTED
      -> EXECUTION_STARTED
      -> RESULT_COMMITTED

If a worker disappears after `EXECUTION_STARTED`:

    REPLAY_SAFE
      -> INTENT_COMMITTED      # eligible for an explicit retry

    IDEMPOTENT_WITH_KEY
      -> INTENT_COMMITTED      # retry with the same key only

    NON_REPLAYABLE
      -> INTERRUPTED           # human/domain recovery required

    UNKNOWN_SIDE_EFFECT
      -> RECONCILIATION_REQUIRED

Never convert `NON_REPLAYABLE` or `UNKNOWN_SIDE_EFFECT` to a fresh pending operation merely because a workflow lease was reclaimed.

## Required durable facts

Persist enough information to decide recovery without process memory:

- run/workflow identity;
- stable effect key within the run;
- replay class;
- request payload or immutable request digest;
- provider/application idempotency key when applicable;
- execution attempt count;
- partial output that must survive a crash;
- final receipt/result when known;
- timestamps for intent, execution start and completion.

A duplicate registration using the same logical effect key but a different payload, replay class, or idempotency key is a conflict, not a retry.

## PostgreSQL reference shape

```sql
CREATE TABLE effect_intents (
  effect_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  run_id text NOT NULL,
  effect_key text NOT NULL,
  replay_class text NOT NULL
    CHECK (replay_class IN (
      'REPLAY_SAFE',
      'IDEMPOTENT_WITH_KEY',
      'NON_REPLAYABLE',
      'UNKNOWN_SIDE_EFFECT'
    )),
  idempotency_key text,
  request jsonb NOT NULL,
  state text NOT NULL DEFAULT 'intent_committed',
  execution_attempts integer NOT NULL DEFAULT 0,
  partial_output jsonb,
  result jsonb,
  UNIQUE (run_id, effect_key)
);
```

The full executable proof is in [`../tests/side_effect_recovery.sql`](../tests/side_effect_recovery.sql).

## Recovery algorithm

1. Register or load the durable intent.
2. Reject a same-key/different-payload conflict.
3. Commit before the external call starts.
4. Mark execution started and increment attempts.
5. Execute the external operation.
6. Persist the receipt/result before treating the effect as complete.
7. After a crash, classify the persisted unfinished state using the replay class.
8. For `IDEMPOTENT_WITH_KEY`, reuse the exact same key.
9. For `NON_REPLAYABLE`, stop automatic execution.
10. For `UNKNOWN_SIDE_EFFECT`, reconcile with the provider or a trusted ledger before any further mutation.

## Failure tests

At minimum, test:

- crash after intent commit but before execution;
- crash after remote acceptance but before receipt persistence;
- duplicate registration with the same payload;
- duplicate registration with a different payload;
- replay-safe retry increments attempts;
- idempotent retry reuses the same key;
- non-replayable retry is refused;
- unknown side effects require reconciliation;
- partial output survives recovery classification;
- completed effects never regress to an executable state.

This pattern is additive to [`durable-workflow-replay.md`](durable-workflow-replay.md). The workflow replay contract controls ownership/versioning; this pattern controls whether an external side effect may execute again.
