![Claude Skill](https://img.shields.io/badge/Claude-Skill-orange) ![MIT License](https://img.shields.io/badge/License-MIT-green)

# postgres-first

You don't need Redis. You don't need n8n. You don't need Elasticsearch, MongoDB, or Pinecone.
You need to actually read the PostgreSQL documentation.

Most teams that think they need six services have three engineers and forty thousand rows.
This skill documents what PostgreSQL already does — with production SQL, not blog posts.

## The Rule Zero

Before adding any external service, answer three questions:

| Question | External service threshold |
|---|---|
| Request rate on this specific operation | > 50,000 req/sec sustained? |
| Team size with dedicated infra capacity | > 8 engineers? |
| Compliance mandate for service isolation | Yes? |

Two or more NO answers: PostgreSQL native. No discussion.

## What's inside

| File | What it covers |
|---|---|
| `SKILL.md` | Full replacement matrix — 8 services, complete SQL |
| `patterns/` | Queue, cache, vector search, pub/sub, rate limiting patterns |
| `migrations/` | Step-by-step migration from Redis, n8n, Elasticsearch, MongoDB |
| `anti-patterns/` | 10 mistakes that destroy PostgreSQL performance, with before/after |

## The origin

Cyclone Chido hit Mayotte on December 14, 2024. 87% of revenue gone in four hours.
Every external service was a dependency that could fail. Redis, n8n, Elasticsearch — all of it.
The rebuild took 41 hours. The lesson was simple: fewer services, more resilience.
These patterns are what remained.

## Install

```bash
claude skill install https://github.com/Thanane15M/postgres-first
```

Or copy `SKILL.md` directly into your project's `.claude/skills/postgres-first/` folder.

## License

MIT
