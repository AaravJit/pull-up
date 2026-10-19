#!/usr/bin/env bash
# Refuses migrations that could destroy data before they reach a hosted
# project. Usage: check-pending-migrations.sh <migration.sql>...
#
# Pull Up's migrations only add things. A statement that drops a table,
# column or schema, truncates, deletes rows (anywhere the migration runs it:
# plain, in a WITH, or in a DO block), or rewrites a column's type is refused
# unless the file carries the line
#   -- pullup: destructive change approved by <name> on <date>
# which a person adds after reviewing what data the change removes.
set -euo pipefail

status=0
for file in "$@"; do
  if grep -qiE '^-- pullup: destructive change approved by [^ ]+' "$file"; then
    echo "$file: destructive changes approved in the file, skipping the check"
    continue
  fi
  # One statement per line, comments removed, whitespace (newlines included)
  # collapsed, so a keyword split across lines is still caught and
  # explanations in comments don't trip the check. Function and procedure
  # bodies are left out: creating one runs none of it. Row updates
  # (backfills) aren't checked here; review those in the pull request.
  # "alter table t drop c" drops a column too (COLUMN is optional); dropping
  # a constraint, default, NOT NULL, identity or generated expression doesn't
  # remove data.
  hits=$(perl -0777 -pe 's{/\*.*?\*/}{ }gs; s/--[^\n]*//g; s/\s+/ /g;
      s{\bcreate (or replace )?(function|procedure)\b.*?(\$\w*\$).*?\3}{create function <body>}gis;
      s/;/;\n/g' "$file" | perl -ne 'print if
    /\bdrop (table|schema|column|materialized view|database|owned)\b/i
    || (/\btruncate\b/i && !/^ ?(grant|revoke)\b/i)
    || /\bdelete from\b/i
    || /\balter table\b.*\bdrop (?!constraint\b|default\b|not null\b|identity\b|expression\b)/i
    || /\balter table\b.*\balter (column )?("[^"]+"|\w+) (set data )?type\b/i')
  if [ -n "$hits" ]; then
    echo "::error file=$file::Possibly destructive statement(s); review and approve in the file first:"
    echo "$hits"
    status=1
  fi
done
exit $status
