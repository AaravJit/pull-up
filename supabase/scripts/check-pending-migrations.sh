#!/usr/bin/env bash
# Refuses migrations that could destroy data before they reach a hosted
# project. Usage: check-pending-migrations.sh <migration.sql>...
#
# Pull Up's migrations only add things. A statement that drops a table,
# column or schema, truncates, or rewrites a column's type is refused unless
# the file carries the line
#   -- pullup: destructive change approved by <name> on <date>
# which a person adds after reviewing what data the change removes.
set -euo pipefail

status=0
for file in "$@"; do
  if grep -qiE '^-- pullup: destructive change approved by [^ ]+' "$file"; then
    echo "$file: destructive changes approved in the file, skipping the check"
    continue
  fi
  # Strip line comments so explanations don't trip the check.
  hits=$(sed 's/--.*$//' "$file" | grep -inE \
    'drop[[:space:]]+(table|schema|column|materialized[[:space:]]+view)|^[[:space:]]*truncate[[:space:]]|alter[[:space:]]+column[[:space:]]+[a-z_"]+[[:space:]]+(set[[:space:]]+data[[:space:]]+)?type' \
    || true)
  if [ -n "$hits" ]; then
    echo "::error file=$file::Possibly destructive statement(s); review and approve in the file first:"
    echo "$hits"
    status=1
  fi
done
exit $status
