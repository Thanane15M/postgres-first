#!/usr/bin/env python3
"""Validate Agent Skill structure, eval fixtures, references, and obvious secrets."""

from __future__ import annotations

import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SKILL = ROOT / "SKILL.md"
EVALS = ROOT / "evals" / "cases.jsonl"

SECRET_PATTERNS = {
    "private key": re.compile(r"BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY"),
    "GitHub token": re.compile(r"gh[pousr]_[A-Za-z0-9_]{20,}"),
    "Telegram bot token": re.compile(r"\b\d{8,12}:[A-Za-z0-9_-]{20,}\b"),
    "credentialed PostgreSQL URI": re.compile(r"postgres(?:ql)?://[^\s/:]+:[^\s/@]+@", re.I),
}

FRONTMATTER_RE = re.compile(r"\A---\n(.*?)\n---\n", re.S)
LINK_RE = re.compile(r"\[[^\]]+\]\(([^)]+)\)")


def fail(message: str, errors: list[str]) -> None:
    errors.append(message)


def parse_frontmatter(text: str, errors: list[str]) -> dict[str, str]:
    match = FRONTMATTER_RE.search(text)
    if not match:
        fail("SKILL.md: missing YAML frontmatter", errors)
        return {}

    block = match.group(1).splitlines()
    values: dict[str, str] = {}
    i = 0
    while i < len(block):
        line = block[i]
        if line.startswith("name:"):
            values["name"] = line.split(":", 1)[1].strip()
        elif line.startswith("description:"):
            value = line.split(":", 1)[1].strip()
            if value == ">":
                parts: list[str] = []
                i += 1
                while i < len(block) and (block[i].startswith("  ") or not block[i].strip()):
                    if block[i].strip():
                        parts.append(block[i].strip())
                    i += 1
                values["description"] = " ".join(parts)
                continue
            values["description"] = value
        i += 1
    return values


def validate_skill(errors: list[str]) -> None:
    text = SKILL.read_text(encoding="utf-8")
    fm = parse_frontmatter(text, errors)
    name = fm.get("name", "")
    description = fm.get("description", "")

    if not re.fullmatch(r"[a-z0-9-]{1,64}", name):
        fail("SKILL.md: name must be 1-64 lowercase letters/numbers/hyphens", errors)
    if not description or len(description) > 1024:
        fail("SKILL.md: description must be 1-1024 characters", errors)
    if len(text.splitlines()) > 500:
        fail("SKILL.md: body exceeds 500-line progressive-disclosure budget", errors)

    for target in LINK_RE.findall(text):
        if target.startswith(("http://", "https://", "#")):
            continue
        clean = target.split("#", 1)[0]
        resolved = (ROOT / clean).resolve()
        if ROOT not in resolved.parents and resolved != ROOT:
            fail(f"SKILL.md: reference escapes repository: {target}", errors)
        elif not resolved.exists():
            fail(f"SKILL.md: missing referenced file: {target}", errors)

    for label, pattern in SECRET_PATTERNS.items():
        if pattern.search(text):
            fail(f"SKILL.md: possible {label}", errors)


def validate_evals(errors: list[str]) -> None:
    if not EVALS.exists():
        fail("evals/cases.jsonl: missing", errors)
        return
    rows = []
    for lineno, raw in enumerate(EVALS.read_text(encoding="utf-8").splitlines(), start=1):
        if not raw.strip():
            continue
        try:
            row = json.loads(raw)
        except json.JSONDecodeError as exc:
            fail(f"evals/cases.jsonl:{lineno}: invalid JSON: {exc}", errors)
            continue
        for key in ("id", "input", "expected_behavior", "forbidden"):
            if key not in row:
                fail(f"evals/cases.jsonl:{lineno}: missing {key}", errors)
        rows.append(row)
    if len(rows) < 3:
        fail("evals/cases.jsonl: at least three evals are required", errors)
    ids = [row.get("id") for row in rows]
    if len(ids) != len(set(ids)):
        fail("evals/cases.jsonl: duplicate eval ids", errors)


def validate_repo_secrets(errors: list[str]) -> None:
    for path in ROOT.rglob("*"):
        if not path.is_file() or ".git" in path.parts:
            continue
        if path.suffix.lower() not in {".md", ".py", ".sql", ".sh", ".yml", ".yaml", ".jsonl", ".txt"}:
            continue
        text = path.read_text(encoding="utf-8", errors="replace")
        for label, pattern in SECRET_PATTERNS.items():
            if pattern.search(text):
                fail(f"{path.relative_to(ROOT)}: possible {label}", errors)


def main() -> int:
    errors: list[str] = []
    validate_skill(errors)
    validate_evals(errors)
    validate_repo_secrets(errors)
    if errors:
        print("\n".join(errors), file=sys.stderr)
        return 1
    print("Agent Skill structure, evals, references, and secret patterns: OK")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
