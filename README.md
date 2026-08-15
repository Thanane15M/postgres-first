# postgres-first

Evidence-based PostgreSQL-first architecture patterns for agents and backend teams.

The project asks a deliberately narrow question: **can PostgreSQL satisfy this workload well enough that another stateful service is not yet justified?** The answer must come from measured requirements and runtime evidence, not from ideology.

## Quality status

- Active skill: `SKILL.md` — concise, progressive-disclosure entry point.
- Full pre-refactor skill preserved at `references/SKILL.pre-2026-08-15.md`.
- Static validation: frontmatter, links, JSONL evals, secret patterns, Python/SQL examples.
- Runtime validation: PostgreSQL 18 schema/pattern smoke tests plus queue lock-concurrency proof.
- Upstream facts and verification dates: `VERIFICATION.md`.

A green parser check means only that examples are syntactically valid. Runtime claims remain `NOT_PROVEN` until the relevant workload and failure mode have been exercised.

## The rule zero

Before adding or removing Redis, MongoDB, Elasticsearch, a vector database, a workflow engine, or another stateful service, record:

| Dimension | Evidence |
|---|---|
| Performance | representative peak load, p95/p99, data size, growth margin |
| Semantics | ordering, replay, fan-out, durability, consistency, availability |
| Operations | restore objectives, blast radius, regional/compliance constraints, team skill, cost |

If evidence is incomplete, the correct answer is `NOT_PROVEN`.

## What is included

| Path | Purpose |
|---|---|
| `SKILL.md` | agent-facing decision workflow and guardrails |
| `patterns/` | advanced PostgreSQL implementation patterns |
| `migrations/` | migration playbooks from common external services |
| `anti-patterns/` | failure modes and corrections |
| `tests/` | executable PostgreSQL/runtime checks |
| `evals/` | agent-behavior evaluation cases |
| `scripts/` | deterministic validation tooling |
| `VERIFICATION.md` | claim/source/runtime evidence matrix |

## Run the checks locally

```bash
python -m pip install -r requirements-dev.txt
python scripts/validate_markdown.py
python scripts/validate_skill.py
```

With PostgreSQL 18 available as `DATABASE_URL`:

```bash
psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f tests/runtime.sql
bash tests/queue_concurrency.sh "$DATABASE_URL"
```

GitHub Actions runs the same quality gates on pushes and pull requests.

## Design principles

1. **Reality over narrative** — parse success is not production proof.
2. **Measure before splitting** — no fixed connection-count, row-count or scale folklore is treated as universal.
3. **Durable state stays durable** — `UNLOGGED`, `LISTEN/NOTIFY` and caches are never promoted to authoritative state.
4. **Specialists remain justified** — use dedicated systems when required semantics, isolation or economics demand them.
5. **Every recommendation has an exit criterion** — define when PostgreSQL stops being the right fit.

## Install as an agent skill

Clone the repository, then copy `SKILL.md` and the referenced directories into the skill directory used by your agent environment.

```bash
git clone https://github.com/Thanane15M/postgres-first.git
```

The repository does not assume a specific agent runtime; `SKILL.md` follows the common filesystem-based Agent Skill pattern.

## License

MIT
