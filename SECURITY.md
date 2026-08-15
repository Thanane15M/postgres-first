# Security policy

## Supported scope

The repository is documentation, deterministic validation code, SQL examples and runtime test fixtures. It does not operate a hosted service or store user credentials.

## Reporting a vulnerability

Please report security issues privately through GitHub's security reporting mechanisms when available. Do not open a public issue containing credentials, exploit payloads against third parties, private infrastructure details, or sensitive data.

Include:

- affected path and commit SHA;
- impact and realistic attack path;
- minimum reproduction steps;
- whether the issue affects documentation only, test tooling, or a recommended production pattern;
- a suggested mitigation if known.

## Repository security rules

- Never commit database credentials, tokens, private keys, customer data or production connection strings.
- Examples use placeholders or environment variables.
- CI permissions remain least-privilege (`contents: read`) unless a reviewed workflow requires more.
- Third-party GitHub Actions must be pinned to full commit SHAs.
- Pull-request workflows must not expose privileged secrets to untrusted fork code.
- `UNLOGGED` tables, caches and `LISTEN/NOTIFY` must never be documented as durable authorities.
- RLS examples are not considered proven until tested through a role that does not bypass RLS.
- A successful syntax/parser check is not a security or production-readiness attestation.

## Secret detection

`scripts/validate_markdown.py` and `scripts/validate_skill.py` reject high-confidence credential patterns in tracked Markdown and skill metadata. GitHub secret scanning/push protection should also remain enabled at repository level when available.

## Dependency handling

Development dependencies exist only to validate repository content. Dependabot updates should be reviewed for compatibility, then validated through the repository quality workflow before merge.
