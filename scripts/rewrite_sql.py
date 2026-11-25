#!/usr/bin/env python3
"""Rewrite a pg_dump-style SQL file so GeoKnight can load it more than once.

The county package creates tables in the jax_demo schema and already uses
CREATE TABLE IF NOT EXISTS. This rewriter:

* points those tables at public (the schema GeoServer publishes)
* leaves string literals alone, so a value that happens to say jax_demo stays
* adds IF NOT EXISTS once when it is missing, and never stacks a second one
* drops each table the file creates before the rest of the script, so a second
  load replaces rows instead of appending them or tripping on constraints
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

SOURCE_SCHEMA = "jax_demo"
TARGET_SCHEMA = "public"
PREPARE_START = "-- geoknight-load: prepare"
PREPARE_END = "-- geoknight-load: end"

# Keyword line only. The optional IF NOT EXISTS is consumed so a second one
# is not inserted in front of an existing one.
_CREATE = re.compile(
    r"^(\s*CREATE\s+(?:OR\s+REPLACE\s+)?)(?:(UNIQUE)\s+)?"
    r"(INDEX|TABLE|SCHEMA|SEQUENCE|UNLOGGED\s+TABLE)"
    r"\s+(?:IF\s+NOT\s+EXISTS\s+)?",
    re.IGNORECASE,
)
_DOUBLE_IF = re.compile(r"(?i)(?:IF\s+NOT\s+EXISTS\s+){2,}")
_SET_CONFIG = re.compile(
    r"(?i)(set_config\(\s*'search_path'\s*,\s*')jax_demo\b",
)
# ogr2ogr PGDump passes the schema as a string to these calls. They are not
# user-visible text, so they follow the table into public. Other string
# values, including a note that happens to say jax_demo, are left alone.
_ADD_GEOMETRY = re.compile(
    r"(?i)((?:AddGeometryColumn|DropGeometryColumn)\s*\(\s*)'jax_demo'",
)
_F_TABLE_SCHEMA = re.compile(
    r"(?i)(f_table_schema\s*=\s*)'jax_demo'",
)
_NAME = (
    r'(?:"[^"]+"|[A-Za-z_][A-Za-z0-9_]*)'
    r'(?:\s*\.\s*(?:"[^"]+"|[A-Za-z_][A-Za-z0-9_]*))?'
)
_TABLE = re.compile(
    rf"(?im)^\s*CREATE\s+(?:UNLOGGED\s+)?TABLE\s+(?:IF\s+NOT\s+EXISTS\s+)?({_NAME})"
)
_SEQUENCE = re.compile(
    rf"(?im)^\s*CREATE\s+SEQUENCE\s+(?:IF\s+NOT\s+EXISTS\s+)?({_NAME})"
)
_PREPARE_BLOCK = re.compile(
    rf"(?s){re.escape(PREPARE_START)}\n.*?{re.escape(PREPARE_END)}\n",
)


def _replace_schema_token(code: str) -> str:
    return re.sub(rf"\b{SOURCE_SCHEMA}\b", TARGET_SCHEMA, code, flags=re.IGNORECASE)


def rewrite_schema(sql: str) -> str:
    """Replace the jax_demo schema outside of string literals and dollar quotes."""
    sql = _SET_CONFIG.sub(rf"\1{TARGET_SCHEMA}", sql)
    sql = _ADD_GEOMETRY.sub(rf"\1'{TARGET_SCHEMA}'", sql)
    sql = _F_TABLE_SCHEMA.sub(rf"\1'{TARGET_SCHEMA}'", sql)
    out: list[str] = []
    i = 0
    n = len(sql)
    while i < n:
        ch = sql[i]
        if ch == "'":
            j = i + 1
            while j < n:
                if sql[j] == "'":
                    if j + 1 < n and sql[j + 1] == "'":
                        j += 2
                        continue
                    j += 1
                    break
                j += 1
            out.append(sql[i:j])
            i = j
            continue
        if ch == '"':
            j = i + 1
            while j < n:
                if sql[j] == '"':
                    if j + 1 < n and sql[j + 1] == '"':
                        j += 2
                        continue
                    j += 1
                    break
                j += 1
            ident = sql[i:j]
            inner = ident[1:-1].replace('""', '"')
            if inner.lower() == SOURCE_SCHEMA:
                out.append(f'"{TARGET_SCHEMA}"')
            else:
                out.append(ident)
            i = j
            continue
        if ch == "$":
            tag = re.match(r"\$[A-Za-z0-9_]*\$", sql[i:])
            if tag:
                marker = tag.group(0)
                end = sql.find(marker, i + len(marker))
                if end == -1:
                    out.append(_replace_schema_token(sql[i:]))
                    i = n
                    break
                end += len(marker)
                out.append(sql[i:end])
                i = end
                continue
        j = i + 1
        while j < n and sql[j] not in "'\"$":
            j += 1
        out.append(_replace_schema_token(sql[i:j]))
        i = j
    return "".join(out)


def ensure_if_not_exists(sql: str) -> str:
    """Make CREATE SCHEMA/TABLE/INDEX/SEQUENCE idempotent without stacking IF NOT EXISTS."""
    lines: list[str] = []
    for line in sql.splitlines(keepends=True):
        stripped = line.lstrip()
        if stripped.startswith("--"):
            lines.append(line)
            continue
        if re.match(r"(?i)\s*CREATE\s+", line):

            def _repl(match: re.Match[str]) -> str:
                unique = "UNIQUE " if match.group(2) else ""
                kind = re.sub(r"\s+", " ", match.group(3))
                return f"{match.group(1)}{unique}{kind} IF NOT EXISTS "

            line = _CREATE.sub(_repl, line, count=1)
            line = _DOUBLE_IF.sub("IF NOT EXISTS ", line)
        lines.append(line)
    return "".join(lines)


def _names(pattern: re.Pattern[str], sql: str) -> list[str]:
    found: list[str] = []
    seen: set[str] = set()
    for match in pattern.finditer(sql):
        # Ignore a CREATE that is only mentioned in a comment. finditer is
        # already anchored at line start, and comment lines are not CREATE.
        name = match.group(1).strip()
        key = re.sub(r"\s+", "", name).lower()
        if key in seen:
            continue
        seen.add(key)
        found.append(name)
    return found


def inject_prepare(sql: str) -> str:
    sql = _PREPARE_BLOCK.sub("", sql)
    tables = _names(_TABLE, sql)
    sequences = _names(_SEQUENCE, sql)
    if not tables and not sequences:
        return sql
    lines = [PREPARE_START]
    for name in tables:
        lines.append(f"DROP TABLE IF EXISTS {name} CASCADE;")
    for name in sequences:
        lines.append(f"DROP SEQUENCE IF EXISTS {name} CASCADE;")
    lines.append(PREPARE_END)
    block = "\n".join(lines) + "\n"
    return block + sql


def rewrite(sql: str) -> str:
    prepared = inject_prepare(ensure_if_not_exists(rewrite_schema(sql)))
    if prepared and not prepared.endswith("\n"):
        prepared += "\n"
    return prepared


def main(argv: list[str]) -> int:
    if len(argv) > 2:
        print("Usage: rewrite_sql.py [file.sql]", file=sys.stderr)
        return 2
    if len(argv) == 2:
        sql = Path(argv[1]).read_text(encoding="utf-8")
    else:
        sql = sys.stdin.read()
    sys.stdout.write(rewrite(sql))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
