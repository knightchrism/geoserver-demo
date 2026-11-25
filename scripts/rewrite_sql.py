#!/usr/bin/env python3
"""Rewrite a pg_dump-style SQL file so GeoKnight can load it more than once.

The county package creates tables in the jax_demo schema and already uses
CREATE TABLE IF NOT EXISTS. This rewriter:

* points those tables at public (the schema GeoServer publishes)
* leaves string literals alone, so a value that happens to say jax_demo stays
* passes COPY ... FROM stdin data through unchanged, up to the \\. line, so an
  apostrophe in a road name cannot hide a later CREATE INDEX or setval
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
# pg_dump writes setval('jax_demo.seq', ...) and ogr2ogr writes
# setval(pg_get_serial_sequence('"jax_demo"."table"', ...). The schema in
# those regclass strings follows the table. A free-standing string does not.
_REGCLASS_SCHEMA = re.compile(
    r"(?i)(\b(?:pg_get_serial_sequence|setval|nextval|currval)\s*\(\s*')"
    r'(?:"jax_demo"|jax_demo)\.'
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


def _rewrite_regclass_schema(match: re.Match[str]) -> str:
    prefix = match.group(1)
    body = match.group(0)[len(prefix) :]
    if body[:1] == '"':
        return f'{prefix}"{TARGET_SCHEMA}".'
    return f"{prefix}{TARGET_SCHEMA}."


def _skip_lexical(sql: str, i: int) -> int | None:
    """If a string, quoted identifier, dollar quote, or comment starts at i,
    return the index just past it. Unclosed constructs run through EOF.
    """
    n = len(sql)
    if i >= n:
        return None
    ch = sql[i]
    if ch == "'":
        j = i + 1
        while j < n:
            if sql[j] == "'":
                if j + 1 < n and sql[j + 1] == "'":
                    j += 2
                    continue
                return j + 1
            j += 1
        return n
    if ch == '"':
        j = i + 1
        while j < n:
            if sql[j] == '"':
                if j + 1 < n and sql[j + 1] == '"':
                    j += 2
                    continue
                return j + 1
            j += 1
        return n
    if ch == "$":
        tag = re.match(r"\$[A-Za-z0-9_]*\$", sql[i:])
        if not tag:
            return None
        marker = tag.group(0)
        end = sql.find(marker, i + len(marker))
        if end == -1:
            return n
        return end + len(marker)
    if ch == "-" and i + 1 < n and sql[i + 1] == "-":
        nl = sql.find("\n", i)
        return n if nl == -1 else nl + 1
    if ch == "/" and i + 1 < n and sql[i + 1] == "*":
        end = sql.find("*/", i + 2)
        return n if end == -1 else end + 2
    return None


def _keyword_at(sql: str, i: int, word: str) -> bool:
    n = len(sql)
    size = len(word)
    if i < 0 or i + size > n:
        return False
    if sql[i : i + size].lower() != word.lower():
        return False
    if i > 0 and (sql[i - 1].isalnum() or sql[i - 1] == "_"):
        return False
    end = i + size
    if end < n and (sql[end].isalnum() or sql[end] == "_"):
        return False
    return True


def _skip_ws_and_comments(sql: str, i: int) -> int:
    n = len(sql)
    while i < n:
        if sql[i].isspace():
            i += 1
            continue
        if sql.startswith("--", i) or sql.startswith("/*", i):
            skipped = _skip_lexical(sql, i)
            if skipped is None or skipped <= i:
                break
            i = skipped
            continue
        break
    return i


def _statement_end(sql: str, start: int) -> int | None:
    i = start
    n = len(sql)
    while i < n:
        skipped = _skip_lexical(sql, i)
        if skipped is not None:
            i = skipped
            continue
        if sql[i] == ";":
            return i + 1
        i += 1
    return None


def _is_copy_from_stdin(statement: str) -> bool:
    i = 0
    n = len(statement)
    while i < n:
        skipped = _skip_lexical(statement, i)
        if skipped is not None:
            i = skipped
            continue
        if _keyword_at(statement, i, "FROM"):
            j = _skip_ws_and_comments(statement, i + 4)
            if _keyword_at(statement, j, "STDIN"):
                return True
        i += 1
    return False


def _copy_data_end(sql: str, start: int) -> int:
    """Index just after the \\. terminator line, or EOF if it is missing."""
    i = start
    n = len(sql)
    while i < n:
        nl = sql.find("\n", i)
        if nl == -1:
            line = sql[i:]
            line_end = n
        else:
            line = sql[i:nl]
            line_end = nl + 1
        if line.endswith("\r"):
            line = line[:-1]
        if line == "\\.":
            return line_end
        if nl == -1:
            return n
        i = line_end
    return n


def _split_copy_regions(sql: str) -> list[tuple[str, str]]:
    """Split SQL into ('sql', text) and ('copy', text) pieces.

    A copy piece is the raw COPY FROM stdin payload, including the \\. line.
    The COPY statement itself stays in the sql piece so its schema can move.
    """
    segments: list[tuple[str, str]] = []
    buf: list[str] = []
    i = 0
    n = len(sql)

    def flush() -> None:
        if buf:
            segments.append(("sql", "".join(buf)))
            buf.clear()

    while i < n:
        skipped = _skip_lexical(sql, i)
        if skipped is not None:
            buf.append(sql[i:skipped])
            i = skipped
            continue
        if _keyword_at(sql, i, "COPY"):
            end = _statement_end(sql, i)
            if end is not None and _is_copy_from_stdin(sql[i:end]):
                buf.append(sql[i:end])
                data_end = _copy_data_end(sql, end)
                flush()
                if data_end > end:
                    segments.append(("copy", sql[end:data_end]))
                i = data_end
                continue
        buf.append(sql[i])
        i += 1
    flush()
    return segments


def _map_outside_copy(sql: str, transform) -> str:
    parts: list[str] = []
    for kind, text in _split_copy_regions(sql):
        parts.append(text if kind == "copy" else transform(text))
    return "".join(parts)


def _rewrite_schema_code(sql: str) -> str:
    """Replace the jax_demo schema outside of string literals and dollar quotes."""
    sql = _SET_CONFIG.sub(rf"\1{TARGET_SCHEMA}", sql)
    sql = _ADD_GEOMETRY.sub(rf"\1'{TARGET_SCHEMA}'", sql)
    sql = _F_TABLE_SCHEMA.sub(rf"\1'{TARGET_SCHEMA}'", sql)
    sql = _REGCLASS_SCHEMA.sub(_rewrite_regclass_schema, sql)
    out: list[str] = []
    i = 0
    n = len(sql)
    while i < n:
        skipped = _skip_lexical(sql, i)
        if skipped is not None and (
            sql.startswith("--", i) or sql.startswith("/*", i)
        ):
            # Comments are not strings. Replace schema words in the whole
            # comment so an apostrophe in the comment cannot hide later SQL.
            out.append(_replace_schema_token(sql[i:skipped]))
            i = skipped
            continue
        if skipped is not None and sql[i] == "'":
            out.append(sql[i:skipped])
            i = skipped
            continue
        if skipped is not None and sql[i] == '"':
            ident = sql[i:skipped]
            inner = ident[1:-1].replace('""', '"') if ident.endswith('"') else ident
            if inner.lower() == SOURCE_SCHEMA:
                out.append(f'"{TARGET_SCHEMA}"')
            else:
                out.append(ident)
            i = skipped
            continue
        if skipped is not None and sql[i] == "$":
            out.append(sql[i:skipped])
            i = skipped
            continue
        j = i + 1
        while j < n and sql[j] not in "'\"$":
            j += 1
        out.append(_replace_schema_token(sql[i:j]))
        i = j
    return "".join(out)


def rewrite_schema(sql: str) -> str:
    """Replace the jax_demo schema outside of string literals, dollar quotes,
    and COPY FROM stdin data.
    """
    return _map_outside_copy(sql, _rewrite_schema_code)


def _ensure_if_not_exists_code(sql: str) -> str:
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


def ensure_if_not_exists(sql: str) -> str:
    return _map_outside_copy(sql, _ensure_if_not_exists_code)


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


def _prepare_block(tables: list[str], sequences: list[str]) -> str:
    if not tables and not sequences:
        return ""
    lines = [PREPARE_START]
    for name in tables:
        lines.append(f"DROP TABLE IF EXISTS {name} CASCADE;")
    for name in sequences:
        lines.append(f"DROP SEQUENCE IF EXISTS {name} CASCADE;")
    lines.append(PREPARE_END)
    return "\n".join(lines) + "\n"


def inject_prepare(sql: str) -> str:
    regions = _split_copy_regions(sql)
    cleaned: list[tuple[str, str]] = []
    for kind, text in regions:
        if kind == "sql":
            cleaned.append((kind, _PREPARE_BLOCK.sub("", text)))
        else:
            cleaned.append((kind, text))
    # A COPY statement often has no trailing newline of its own; that newline
    # belongs to the data block. Put one back so a later CREATE still matches
    # at the start of a line. The text written below keeps the original bytes.
    sql_lines: list[str] = []
    for kind, text in cleaned:
        if kind != "sql" or not text:
            continue
        if sql_lines and not sql_lines[-1].endswith("\n"):
            sql_lines.append("\n")
        sql_lines.append(text)
    sql_only = "".join(sql_lines)
    block = _prepare_block(_names(_TABLE, sql_only), _names(_SEQUENCE, sql_only))
    return block + "".join(text for _, text in cleaned)


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
