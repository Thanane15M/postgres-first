# Temporal authorization over durable history

Static capability checks answer whether an actor may call a tool in general. Temporal authorization answers whether the action is allowed **now**, given what has already happened.

Example:

> allow `git_push` only when tests and the security scan passed for the same revision, and no later failing test invalidated that evidence.

## Authority boundaries

Keep these concerns separate:

1. **Authoritative audit ledger** — append-only ordered facts and requests.
2. **Policy versions** — immutable policy definitions with an activation point in the ledger.
3. **Derived current state** — optional projection/cache for fast reads; reconstructible from the ledger.
4. **Enforcement point** — the harness/tool boundary that must actually block denied operations.

A policy engine cannot prove provenance by itself. If callers can forge `tests_passed` or bypass the enforcement point, a correct policy still produces unsafe outcomes.

## Ordering rule

Concurrent writes need an explicit linearization point. In the reference proof, a PostgreSQL advisory transaction lock serializes ledger append/evaluation and an identity `event_id` records that order.

Policy activation is itself a durable event. A request is evaluated against the policy version active at the request event, not whatever policy happens to be current when a delayed evaluator resumes.

## Two-phase request and decision

Use two durable phases:

    ACTION_REQUEST (committed)
      -> policy evaluation
      -> AUTHZ_DECISION (linked to request)

This survives a crash after the request was persisted but before a verdict existed. Re-evaluating the same request must return the existing decision rather than create a second one.

## Example evidence rule

For a `git_push` request on revision `R`:

- the latest `tests` fact before the request for `R` must be `pass`;
- the latest `security_scan` fact before the request for `R` must be `pass`;
- the decision records the exact `policy_version`;
- facts that arrive after the request cannot retroactively justify that request.

This is a reference rule, not a universal CI policy. Production policies should encode the actual required evidence, freshness windows, identity/provenance checks and approval requirements.

## Crash and concurrency properties

Test at least:

- two concurrent action requests receive distinct ordered ledger events;
- concurrent evaluation produces one decision per request;
- a request left without a decision can be reconciled later;
- a policy activated after a request does not rewrite the request's policy version;
- later failing evidence denies later requests;
- the derived current-state projection may change without mutating historical decisions.

The executable PostgreSQL proof is in [`../tests/temporal_authorization_setup.sql`](../tests/temporal_authorization_setup.sql) and [`../tests/temporal_authorization.sh`](../tests/temporal_authorization.sh).

## Security notes

- Authenticate event producers.
- Bind evidence to the exact artifact/revision/tenant it claims to describe.
- Keep policy/control-plane writes separately authorized.
- Do not let model text create trusted evidence directly.
- Do not delete audit events merely because a projection was rebuilt.
- Treat external approvals and scan receipts as side effects with their own provenance and replay rules.

Temporal authorization is complementary to durable workflow replay: replay answers how execution resumes; temporal authorization answers whether the next external action is currently permitted.
