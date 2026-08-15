# Contributing

Contributions are welcome when they make a claim more accurate, more testable, or easier for an agent to apply safely.

## Before changing a pattern

1. State the workload and the claim being changed.
2. Prefer PostgreSQL primary documentation for database semantics.
3. Avoid universal numeric thresholds unless an authoritative source defines them.
4. Add or update an eval case for agent behavior.
5. Add a runtime regression test when the change affects executable SQL or concurrency semantics.
6. Preserve historical guidance that may still be useful by moving it to a clearly labelled legacy/reference file rather than silently deleting it.

## Local validation

```bash
python -m pip install -r requirements-dev.txt
python scripts/validate_markdown.py
python scripts/validate_skill.py
```

For runtime checks, provide a PostgreSQL 18 `DATABASE_URL`:

```bash
psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f tests/runtime.sql
bash tests/queue_concurrency.sh "$DATABASE_URL"
```

## Pull requests

A PR should explain:

- what changed and why;
- which previous claim or failure mode it addresses;
- evidence used;
- tests/evals added or updated;
- any property that remains `NOT_PROVEN`.

Do not describe a change as production-ready solely because Markdown, Python or SQL parses.
