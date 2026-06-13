"""Validate Python examples and reject high-confidence secret patterns."""

from __future__ import annotations

import ast
import re
import sys
from pathlib import Path

try:
    from pglast import parse_sql
except ImportError:  # Local fallback; CI installs the pinned parser.
    parse_sql = None


ROOT = Path(__file__).resolve().parents[1]
PYTHON_BLOCK = re.compile(r"```python\s*\n(.*?)```", re.DOTALL)
SQL_BLOCK = re.compile(r"```sql\s*\n(.*?)```", re.DOTALL)
SECRET_PATTERNS = {
    "private key": re.compile(r"BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY"),
    "GitHub token": re.compile(r"gh[pousr]_[A-Za-z0-9_]{20,}"),
    "Telegram bot token": re.compile(r"\b\d{8,12}:[A-Za-z0-9_-]{20,}\b"),
    "credentialed PostgreSQL URI": re.compile(
        r"postgres(?:ql)?://[^\s/:]+:[^\s/@]+@", re.IGNORECASE
    ),
}


def main() -> int:
    errors: list[str] = []
    python_checked = 0
    sql_checked = 0

    for path in sorted(ROOT.rglob("*.md")):
        if ".git" in path.parts:
            continue
        text = path.read_text(encoding="utf-8")

        for label, pattern in SECRET_PATTERNS.items():
            if pattern.search(text):
                errors.append(f"{path.relative_to(ROOT)}: possible {label}")

        for index, match in enumerate(PYTHON_BLOCK.finditer(text), start=1):
            python_checked += 1
            try:
                ast.parse(match.group(1))
            except SyntaxError as exc:
                line = text[: match.start(1)].count("\n") + (exc.lineno or 1)
                errors.append(
                    f"{path.relative_to(ROOT)}:{line}: Python block {index}: {exc.msg}"
                )

        if parse_sql is not None:
            for index, match in enumerate(SQL_BLOCK.finditer(text), start=1):
                sql_checked += 1
                try:
                    parse_sql(match.group(1))
                except Exception as exc:
                    line = text[: match.start(1)].count("\n") + 1
                    errors.append(
                        f"{path.relative_to(ROOT)}:{line}: SQL block {index}: {exc}"
                    )

    if errors:
        print("\n".join(errors), file=sys.stderr)
        return 1

    print(
        f"Validated {python_checked} Python blocks and {sql_checked} SQL blocks."
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
