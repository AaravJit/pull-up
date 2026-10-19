#!/usr/bin/env python3
"""Refuses migrations that could destroy data before they reach a hosted project.

Usage: check_destructive.py <migration.sql>...   (check-pending-migrations.sh calls it)

Pull Up's migrations only add things. A migration that drops a table, column
or schema, truncates, deletes rows or rewrites a column's type is refused
unless the file carries the line
    -- pullup: destructive change approved by <name> on <date>
which a person adds after reviewing what data the change removes.

The SQL is lexed, not grepped: comments, string literals, quoted names and
dollar-quoted bodies are recognised, so neither a keyword split across lines
nor a comment marker inside a string hides a statement. What runs is checked:
top-level statements, DO blocks, the bodies of functions or procedures the
same file calls, and triggers it installs when it (or a routine it calls)
then writes to their table.
Bodies that are only created are not, since creating one runs none of it.
Dynamic SQL (EXECUTE) that runs is refused, since its text is built at run
time. Row updates (backfills) aren't checked; review those in the pull request.
"""
import re
import sys

APPROVAL = re.compile(r"-- pullup: destructive change approved by \S+", re.I)
IDENT_CHAR = re.compile(r"[A-Za-z0-9_$]")
DOLLAR_TAG = re.compile(r"\$([A-Za-z_][A-Za-z0-9_]*)?\$")

DESTRUCTIVE = [
    (re.compile(r"\bdrop (table|schema|column|materialized view|database|owned)\b"), "drops {0}"),
    (re.compile(r"\btruncate\b"), "truncates"),
    (re.compile(r"\bdelete from\b"), "deletes rows"),
    # "alter table t drop c" drops a column (COLUMN is optional); dropping a
    # constraint, default, NOT NULL, identity or expression removes no data.
    (re.compile(r"\balter table\b.*\bdrop (?!constraint\b|default\b|not null\b|identity\b|expression\b)"), "drops a column"),
    (re.compile(r"\balter table\b.*\balter (column )?(\"[^\"]+\"|\w+) (set data )?type\b"), "rewrites a column's type"),
]


class Statement:
    def __init__(self, code, bodies, literals):
        self.code = code          # lowercased, comments removed, literals as '', bodies as $n$
        self.bodies = bodies      # dollar-quoted bodies, raw text
        self.literals = literals  # string literal contents


ATOMIC = re.compile(r"^\s*create (or replace )?(function|procedure)\b.*?\bbegin atomic\b(.*)$", re.S)


def inside_atomic_body(code):
    """True inside a SQL-standard body (BEGIN ATOMIC ... END), whose statements end in ; too."""
    m = ATOMIC.match("".join(code).lower())
    if not m:
        return False
    return atomic_depth(m.group(3)) > 0


def atomic_depth(body):
    words = re.findall(r"\b(begin|case|end)\b", re.sub(r'"[^"]*"', " ", body))  # not "quoted" names
    return 1 + sum(1 if w in ("begin", "case") else -1 for w in words)


def lex(sql, line_comments=None):
    """Splits SQL into statements at top-level semicolons.

    line_comments, if given, collects the -- comments that start a line.
    """
    statements, code, bodies, literals = [], [], [], []
    i, n = 0, len(sql)

    def finish():
        text = re.sub(r"\s+", " ", "".join(code)).strip().lower()
        if text:
            statements.append(Statement(text, list(bodies), list(literals)))
        code.clear(); bodies.clear(); literals.clear()

    while i < n:
        c = sql[i]
        if sql.startswith("--", i):
            j = sql.find("\n", i)
            j = n if j < 0 else j
            if line_comments is not None and sql[sql.rfind("\n", 0, i) + 1:i].strip() == "":
                line_comments.append(sql[i:j])
            i = j
            code.append(" ")
        elif sql.startswith("/*", i):
            depth, i = 1, i + 2
            while i < n and depth:
                if sql.startswith("/*", i):
                    depth, i = depth + 1, i + 2
                elif sql.startswith("*/", i):
                    depth, i = depth - 1, i + 2
                else:
                    i += 1
            code.append(" ")
        elif c == "'":
            escapes = i > 0 and sql[i - 1] in "eE" and (i < 2 or not IDENT_CHAR.match(sql[i - 2]))
            j, buf = i + 1, []
            while j < n:
                if escapes and sql[j] == "\\" and j + 1 < n:
                    buf.append(sql[j:j + 2]); j += 2
                elif sql[j] == "'" and sql.startswith("''", j):
                    buf.append("'"); j += 2
                elif sql[j] == "'":
                    break
                else:
                    buf.append(sql[j]); j += 1
            literals.append("".join(buf))
            code.append("''")
            i = j + 1
        elif c == '"':
            j = i + 1
            while j < n and not (sql[j] == '"' and not sql.startswith('""', j)):
                j += 2 if sql.startswith('""', j) else 1
            code.append(sql[i:j + 1])
            i = j + 1
        elif c == "$" and (i == 0 or not IDENT_CHAR.match(sql[i - 1])) and DOLLAR_TAG.match(sql, i):
            tag = DOLLAR_TAG.match(sql, i).group(0)
            end = sql.find(tag, i + len(tag))
            end = n if end < 0 else end
            code.append(f" ${len(bodies)}$ ")
            bodies.append(sql[i + len(tag):end])
            i = end + len(tag)
        elif c == ";" and not inside_atomic_body(code):
            finish()
            i += 1
        else:
            code.append(c)
            i += 1
    finish()
    return statements


FUNCTION = re.compile(r"^create (or replace )?(function|procedure) ((\"[^\"]+\"|\w+)\.)?(\"[^\"]+\"|\w+)")
NAME = r"(?:(?:\"[^\"]+\"|\w+)\.)?(\"[^\"]+\"|\w+)"
TRIGGER = re.compile(rf"^create (or replace )?(constraint )?trigger .*? on (only )?{NAME} .*\bexecute (function|procedure) {NAME} ?\(")
# Anywhere in a statement (after WITH, IF ... THEN, a label...): a stray
# match such as "before update on" only names a table nothing writes.
DML = re.compile(rf"\b(insert into|update|delete from|merge into|copy)( only)? {NAME}")
# Statements that name a function without running it.
NOT_A_CALL = re.compile(
    r"^(grant|revoke|comment|alter (function|procedure|policy)|drop (function|procedure|trigger|policy)"
    r"|create (or replace )?(constraint )?trigger|create policy|create (or replace )?view|create (unique )?index)\b")


def bare(name):
    return name.strip('"')


def written(st):
    return {bare(m.group(3)) for m in DML.finditer(st.code)}


def hits_in(code):
    found = []
    for pattern, what in DESTRUCTIVE:
        m = pattern.search(code)
        if not m:
            continue
        if what == "truncates" and re.match(r"(grant|revoke)\b", code):
            continue
        found.append(what.format(*m.groups()))
    return found


# EXECUTE runs a string as SQL; EXECUTE FUNCTION (triggers) and GRANT EXECUTE ON don't.
DYNAMIC = re.compile(r"\bexecute\b(?! (function|procedure|on)\b)")
BLOCK_WORDS = re.compile(r"^((begin( atomic)?|then|else|loop|exception when [\w ]+? then)\b ?)+")


def walk(statements, depth=0):
    """Every statement that runs: top level and inside DO blocks."""
    for st in statements:
        # In a PL/pgSQL body the statement can follow BEGIN, THEN, ELSE...
        st.code = BLOCK_WORDS.sub("", st.code)
        yield st
        if st.code.startswith("do ") and depth < 5:
            for body in st.bodies + st.literals:
                yield from walk(lex(body), depth + 1)


def body_statements(st):
    # A body can be dollar-quoted, an ordinary string literal (AS '...') or
    # SQL-standard (RETURN expr, BEGIN ATOMIC ... END), which is part of the
    # statement itself; so everything after the routine's name is checked.
    bodies = st.bodies + st.literals + [st.code[FUNCTION.match(st.code).end():]]
    atomic = ATOMIC.match(st.code)
    if atomic:
        bodies.append(atomic.group(3))  # its statements, so writes are seen as writes
    return [b for body in bodies for b in walk(lex(body))]


def approved(sql):
    """The approval line, only as a real comment at the start of a line."""
    comments = []
    lex(sql, comments)
    return any(APPROVAL.match(c) for c in comments)


def check(sql):
    """Reasons the migration needs approval; empty when it only adds things."""
    if approved(sql):
        return []
    statements = list(walk(lex(sql)))
    # By bare name, keeping every overload and schema: a call counts all of them.
    created = {}
    for st in statements:
        if FUNCTION.match(st.code):
            created.setdefault(bare(FUNCTION.match(st.code).group(5)), []).append(st)

    def direct(st):
        reasons = hits_in(st.code)
        # Dynamic SQL is text built at run time ('drop ' || 'table x',
        # format(...)), so what it does can't be read from the file.
        if DYNAMIC.search(st.code):
            reasons.append("runs dynamic SQL (EXECUTE), which can't be checked")
        return reasons

    def calls(st):
        if NOT_A_CALL.match(st.code) or FUNCTION.match(st.code):
            return []
        return [name for name in created if re.search(rf"(^|[^\w.]|\.){re.escape(name)} ?\(", st.code)]

    # Every trigger the file installs, by table. Inside a routine the order
    # isn't known (it may run after the trigger exists), so all of them count.
    all_triggers = {}
    for st in statements:
        m = TRIGGER.match(st.code)
        if m:
            all_triggers.setdefault(bare(m.group(4)), []).append(bare(m.group(6)))

    # What each function created here does when run, following calls between
    # them and the triggers their writes fire (a fixed point, so the order
    # they're created in doesn't matter).
    does = {name: [r for st in sts for b in body_statements(st) for r in direct(b)] for name, sts in created.items()}
    changed = True
    while changed:
        changed = False
        for name, sts in created.items():
            for b in (b for st in sts for b in body_statements(st)):
                runs = [("calls", other) for other in calls(b)]
                runs += [("fires", fn) for table in written(b) for fn in all_triggers.get(table, [])]
                for how, other in runs:
                    if other != name and other in does:
                        extra = [f"{how} {other}(), which {r}" for r in does[other] if f" {name}()" not in r]
                        new = [r for r in extra if r not in does[name]]
                        if new:
                            does[name] += new
                            changed = True

    # Triggers installed so far, by table: a write fires those created before it.
    triggers = {}
    problems = []
    for st in statements:
        m = TRIGGER.match(st.code)
        if m and does.get(bare(m.group(6))):
            triggers.setdefault(bare(m.group(4)), []).extend(
                f"fires {bare(m.group(6))}(), which {r}" for r in does[bare(m.group(6))])
        atomic = ATOMIC.match(st.code)
        if atomic and atomic_depth(atomic.group(3)) != 0:
            # Its END wasn't found, so the statements after it may be inside.
            problems.append(f"{st.code[:200]}: BEGIN ATOMIC body doesn't close, so the rest of the file can't be checked")
            continue
        if FUNCTION.match(st.code):
            continue  # creating it runs nothing; calls are checked
        reasons = direct(st)
        for name in calls(st):
            reasons += [f"calls {name}(), which {r}" for r in does[name]]
        for table in written(st):
            reasons += triggers.get(table, [])
        if reasons:
            problems.append(f"{st.code[:200]}: {', '.join(dict.fromkeys(reasons))}")
    return problems


def main(paths):
    status = 0
    for path in paths:
        with open(path, encoding="utf-8") as f:
            sql = f.read()
        if approved(sql):
            print(f"{path}: destructive changes approved in the file, skipping the check")
            continue
        problems = check(sql)
        if problems:
            print(f"::error file={path}::Possibly destructive statement(s); review and approve in the file first:")
            for p in problems:
                print(f"  {p}")
            status = 1
    return status


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
