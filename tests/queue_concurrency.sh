#!/usr/bin/env bash
set -euo pipefail

DATABASE_URL="${1:-${DATABASE_URL:-}}"
if [[ -z "$DATABASE_URL" ]]; then
  echo "usage: $0 <postgresql-url> or set DATABASE_URL" >&2
  exit 2
fi

psql "$DATABASE_URL" -v ON_ERROR_STOP=1 <<'SQL'
DROP TABLE IF EXISTS skill_queue_concurrency;
CREATE TABLE skill_queue_concurrency (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  status text NOT NULL DEFAULT 'pending'
);
INSERT INTO skill_queue_concurrency (status) VALUES ('pending'), ('pending');
SQL

out_a="$(mktemp)"
out_b="$(mktemp)"
trap 'rm -f "$out_a" "$out_b"; psql "$DATABASE_URL" -qAtc "DROP TABLE IF EXISTS skill_queue_concurrency" >/dev/null 2>&1 || true' EXIT

psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -qAt <<'SQL' >"$out_a" &
BEGIN;
SELECT id
FROM skill_queue_concurrency
WHERE status = 'pending'
ORDER BY id
LIMIT 1
FOR UPDATE SKIP LOCKED;
SELECT pg_sleep(3);
COMMIT;
SQL
pid_a=$!

sleep 0.5

psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -qAt <<'SQL' >"$out_b"
BEGIN;
SELECT id
FROM skill_queue_concurrency
WHERE status = 'pending'
ORDER BY id
LIMIT 1
FOR UPDATE SKIP LOCKED;
COMMIT;
SQL

wait "$pid_a"

id_a="$(grep -E '^[0-9]+$' "$out_a" | head -n1)"
id_b="$(grep -E '^[0-9]+$' "$out_b" | head -n1)"

if [[ -z "$id_a" || -z "$id_b" ]]; then
  echo "failed to capture queue ids" >&2
  exit 1
fi
if [[ "$id_a" == "$id_b" ]]; then
  echo "SKIP LOCKED failure: both consumers selected row $id_a" >&2
  exit 1
fi

echo "queue concurrency: OK (consumer A=$id_a, consumer B=$id_b)"
