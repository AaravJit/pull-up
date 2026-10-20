#!/usr/bin/env bash
# Refuses migrations that could destroy data before they reach a hosted
# project. Usage: check-pending-migrations.sh <migration.sql>...
#
# A migration that drops a table, column or schema, truncates, deletes rows or
# rewrites a column's type is refused unless the file carries the line
#   -- pullup: destructive change approved by <name> on <date>
#   (a real name and a YYYY-MM-DD date)
# which a person adds after reviewing what data the change removes.
# check_destructive.py has the details; its tests run in backend CI.
set -euo pipefail
exec python3 "$(dirname "$0")/check_destructive.py" "$@"
