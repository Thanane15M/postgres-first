![Claude Skill](https://img.shields.io/badge/Claude-Skill-orange) ![MIT License](https://img.shields.io/badge/License-MIT-green)

# postgres-first

You may not need Redis, n8n, Elasticsearch, MongoDB, or Pinecone yet.
Measure the workload first, then use PostgreSQL where it meets the reliability,
latency, durability, and operational requirements.

Most teams that think they need six services have three engineers and forty thousand rows.
This skill documents what PostgreSQL already does — with production SQL, not blog posts.

## The Rule Zero

Before adding any external service, measure these dimensions:

| Dimension | Evidence to collect |
|---|---|
| Throughput and tail latency | Sustained load test at expected peak and growth margin |
| Durability and delivery semantics | Loss tolerance, ordering, replay, retention, recovery |
| Operational and compliance needs | Isolation, blast radius, skills, cost, regional constraints |

Start with PostgreSQL when it satisfies those measured requirements. Split out a
specialized service only when evidence justifies the added operational cost.

## What's inside

| File | What it covers |
|---|---|
| `SKILL.md` | Full replacement matrix — 8 services, complete SQL |
| `patterns/` | Queue, cache, vector search, pub/sub, rate limiting patterns |
| `migrations/` | Step-by-step migration from Redis, n8n, Elasticsearch, MongoDB |
| `anti-patterns/` | 10 mistakes that destroy PostgreSQL performance, with before/after |

## The origin

Cyclone Chido exposed how infrastructure dependencies amplify recovery work.
The lesson was simple: fewer justified services can mean a smaller failure surface.
These patterns capture that approach without treating PostgreSQL as a universal answer.

## Install

```bash
git clone https://github.com/Thanane15M/postgres-first.git
```

Copy `SKILL.md` and the reference directories into your agent's local skills directory.

## License

MIT
