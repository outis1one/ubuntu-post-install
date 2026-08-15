#!/usr/bin/env python3
"""
fix_pikapods_dump.py — Patches two confirmed Adminer PostgreSQL-export bugs
in a Mattermost SQL dump, before importing it via migrate-from-pikapods.sh.

Bug 1: Adminer omits quotes around enum-label DEFAULT values, e.g.
       DEFAULT link            instead of   DEFAULT 'link'
       DEFAULT client_credentials instead of DEFAULT 'client_credentials'
       This makes Postgres treat the label as a column reference, which is
       illegal in a DEFAULT expression, so the whole CREATE TABLE fails.

Bug 2: Adminer serializes PostgreSQL boolean columns as bare integer
       literals (0 / 1) in INSERT statements instead of true/false.
       Postgres does not implicitly cast integer literals to boolean, so
       every row touching one of those columns is rejected.

Bug 2's fix parses each CREATE TABLE in the dump to find every column
declared as `boolean` (not a hand-curated list from partial error
messages — Postgres only reports the FIRST bad column per row, so a
list built from error output alone would likely be incomplete). It then
rewrites only the VALUES-tuple positions that correspond to those
specific boolean columns, leaving every other value in the row
(including other literal 0/1 integers) untouched.

Usage:
    python3 fix_pikapods_dump.py input.sql output.sql

Always writes to a NEW file — never modifies the input in place — so the
original export is preserved if something looks wrong afterward.
"""
import re
import sys


def split_top_level(s, sep=","):
    """Split s on sep, but only outside single-quoted strings and outside
    nested parens. '' inside a quoted string is the SQL escape for a
    literal quote and does not end the string."""
    parts = []
    buf = []
    depth = 0
    in_quote = False
    i = 0
    n = len(s)
    while i < n:
        c = s[i]
        if in_quote:
            if c == "'":
                # doubled quote = escaped literal quote, stays in_quote
                if i + 1 < n and s[i + 1] == "'":
                    buf.append("''")
                    i += 2
                    continue
                in_quote = False
                buf.append(c)
                i += 1
                continue
            buf.append(c)
            i += 1
            continue
        if c == "'":
            in_quote = True
            buf.append(c)
            i += 1
            continue
        if c == "(":
            depth += 1
            buf.append(c)
            i += 1
            continue
        if c == ")":
            depth -= 1
            buf.append(c)
            i += 1
            continue
        if c == sep and depth == 0:
            parts.append("".join(buf))
            buf = []
            i += 1
            continue
        buf.append(c)
        i += 1
    parts.append("".join(buf))
    return parts


def split_statements(sql_text):
    """Split a whole dump into individual statements at semicolons that
    are not inside a quoted string. Returns list of (statement_text,
    trailing_terminator) so the exact original text can be reassembled
    byte-for-byte from the pieces."""
    stmts = []
    buf = []
    in_quote = False
    i = 0
    n = len(sql_text)
    while i < n:
        c = sql_text[i]
        if in_quote:
            buf.append(c)
            if c == "'":
                if i + 1 < n and sql_text[i + 1] == "'":
                    buf.append(sql_text[i + 1])
                    i += 2
                    continue
                in_quote = False
            i += 1
            continue
        if c == "'":
            in_quote = True
            buf.append(c)
            i += 1
            continue
        if c == ";":
            buf.append(c)
            stmts.append("".join(buf))
            buf = []
            i += 1
            continue
        buf.append(c)
        i += 1
    if buf:
        stmts.append("".join(buf))
    return stmts


CREATE_TABLE_NAME_RE = re.compile(
    r'CREATE TABLE\s+(?:"public"\.)?"([^"]+)"\s*\(',
    re.IGNORECASE,
)
INSERT_RE = re.compile(
    r'^(INSERT INTO\s+(?:"public"\.)?"([^"]+)"\s*\()([^)]*)\)\s*VALUES\s*(.*);\s*$',
    re.IGNORECASE | re.DOTALL,
)


def find_matching_paren(s, open_idx):
    """Return the index of the ')' matching the '(' at open_idx, skipping
    over quoted strings so a paren inside a quoted default value (e.g. a
    function call in a DEFAULT expression) doesn't miscount depth."""
    depth = 0
    in_quote = False
    i = open_idx
    n = len(s)
    while i < n:
        c = s[i]
        if in_quote:
            if c == "'":
                if i + 1 < n and s[i + 1] == "'":
                    i += 2
                    continue
                in_quote = False
            i += 1
            continue
        if c == "'":
            in_quote = True
            i += 1
            continue
        if c == "(":
            depth += 1
        elif c == ")":
            depth -= 1
            if depth == 0:
                return i
        i += 1
    return -1


def parse_boolean_columns(create_table_stmt):
    """Given a full CREATE TABLE statement (trailing syntax after the
    closing paren — WITHOUT OIDS, TABLESPACE, etc — is fine, not assumed
    absent), return the set of column names declared as boolean."""
    name_m = CREATE_TABLE_NAME_RE.search(create_table_stmt)
    if not name_m:
        return set()
    open_idx = name_m.end() - 1  # the '(' the regex matched
    close_idx = find_matching_paren(create_table_stmt, open_idx)
    if close_idx == -1:
        return set()
    body = create_table_stmt[open_idx + 1 : close_idx]
    cols = set()
    for coldef in split_top_level(body):
        coldef = coldef.strip()
        cm = re.match(r'^"([^"]+)"\s+([A-Za-z_][A-Za-z0-9_]*)', coldef)
        if cm and cm.group(2).lower() == "boolean":
            cols.add(cm.group(1))
    return cols


def fix_default_quoting(stmt):
    """Bug 1: unquoted enum-label DEFAULTs. Only touches DEFAULT clauses
    that name one of the two enum types confirmed broken in this export
    (channel_bookmark_type, outgoingoauthconnections_granttype) — narrow
    and conservative rather than a blanket 'quote anything after DEFAULT'
    rule that could misfire on legitimate unquoted defaults elsewhere
    (numbers, now(), etc)."""
    stmt, n1 = re.subn(
        r"(channel_bookmark_type\s+DEFAULT\s+)([A-Za-z_][A-Za-z0-9_]*)(?=[,\)])",
        r"\1'\2'",
        stmt,
    )
    stmt, n2 = re.subn(
        r"(outgoingoauthconnections_granttype\s+DEFAULT\s+)([A-Za-z_][A-Za-z0-9_]*)(?=[,\)])",
        r"\1'\2'",
        stmt,
    )
    return stmt, n1 + n2


def patch_insert_booleans(stmt, table, col_list_raw, values_raw, bool_cols):
    """Rewrite bare 0/1 literals to false/true at the positions in
    col_list_raw that correspond to bool_cols. Returns (new_values_text,
    count_of_values_changed)."""
    col_names = [c.strip().strip('"') for c in split_top_level(col_list_raw)]
    bool_positions = {i for i, c in enumerate(col_names) if c in bool_cols}
    if not bool_positions:
        return values_raw, 0

    tuples = split_top_level(values_raw)
    changed = 0
    new_tuples = []
    for tup in tuples:
        tup_stripped = tup.strip()
        if not (tup_stripped.startswith("(") and tup_stripped.endswith(")")):
            new_tuples.append(tup)
            continue
        inner = tup_stripped[1:-1]
        vals = split_top_level(inner)
        for pos in bool_positions:
            if pos >= len(vals):
                continue
            v = vals[pos].strip()
            if v == "0":
                vals[pos] = "false"
                changed += 1
            elif v == "1":
                vals[pos] = "true"
                changed += 1
        prefix = tup[: len(tup) - len(tup.lstrip())]
        suffix = tup[len(tup.rstrip()):]
        new_tuples.append(prefix + "(" + ",".join(vals) + ")" + suffix)
    return ",".join(new_tuples), changed


def process(input_path, output_path):
    with open(input_path, "r", encoding="utf-8", errors="surrogateescape") as f:
        text = f.read()

    statements = split_statements(text)
    bool_cols_by_table = {}
    out = []
    default_fixes = 0
    total_value_fixes = 0
    tables_patched = set()

    for stmt in statements:
        stripped = stmt.strip()
        upper = stripped.upper()

        if upper.startswith("CREATE TABLE"):
            fixed_stmt, n = fix_default_quoting(stmt)
            default_fixes += n
            name_m = CREATE_TABLE_NAME_RE.search(fixed_stmt)
            if name_m:
                bool_cols_by_table[name_m.group(1)] = parse_boolean_columns(fixed_stmt)
            out.append(fixed_stmt)
            continue

        if upper.startswith("INSERT INTO"):
            m = INSERT_RE.match(stripped)
            if m:
                prefix, table, col_list_raw, values_raw = m.groups()
                bool_cols = bool_cols_by_table.get(table, set())
                if bool_cols:
                    new_values, n = patch_insert_booleans(
                        stripped, table, col_list_raw, values_raw, bool_cols
                    )
                    if n:
                        total_value_fixes += n
                        tables_patched.add(table)
                        rebuilt = f'{prefix}{col_list_raw}) VALUES {new_values};'
                        out.append(rebuilt)
                        continue
            out.append(stmt)
            continue

        out.append(stmt)

    with open(output_path, "w", encoding="utf-8", errors="surrogateescape") as f:
        f.write("".join(out))

    print(f"DEFAULT-clause quoting fixes: {default_fixes}")
    print(f"Boolean literal fixes: {total_value_fixes} across {len(tables_patched)} table(s)")
    if tables_patched:
        print("Tables patched: " + ", ".join(sorted(tables_patched)))


if __name__ == "__main__":
    if len(sys.argv) != 3:
        print(f"Usage: {sys.argv[0]} input.sql output.sql", file=sys.stderr)
        sys.exit(1)
    process(sys.argv[1], sys.argv[2])
