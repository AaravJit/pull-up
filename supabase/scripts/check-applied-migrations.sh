#!/usr/bin/env bash
# Keeps the repository and an already-deployed project from drifting apart.
# Usage: check-applied-migrations.sh [--complete] [manifest]
#   (default supabase/applied/staging.sha256)
#
# The manifest lists every migration deployed (or about to be) to the project, with its
# SHA-256. `supabase db push` only compares versions, so an applied file
# edited afterwards would never reach the project. This refuses:
#   * an applied migration whose file has changed (add a new migration instead);
#   * a new migration numbered at or below the newest applied one (db push
#     would skip it or refuse to run, depending on flags).
#   * an applied migration that main has but this branch doesn't (deleted or
#     renamed: the project keeps it while fresh databases lose it).
# Applied files that neither this branch nor main has yet are skipped: they
# arrive with the pull request that adds them. Set PULLUP_MIGRATIONS_BASE to
# compare with another ref than origin/main.
#
# --complete (the deploy workflow): every migration must already be recorded,
# so nothing reaches a project without its checksum being guarded afterwards.
set -euo pipefail

complete=0
if [ "${1:-}" = "--complete" ]; then complete=1; shift; fi
manifest=${1:-supabase/applied/staging.sha256}
dir=supabase/migrations
base=${PULLUP_MIGRATIONS_BASE:-origin/main}
status=0
newest=""

if ! git rev-parse --verify -q "$base^{commit}" >/dev/null; then
  echo "::error::$base isn't available, so a removed migration can't be told from one still to come. Fetch it first (git fetch origin main)."
  exit 1
fi

# Lines main already records stay, unchanged: dropping one (with its file, or
# by regenerating the manifest) would hide a migration the project has.
if git cat-file -e "$base:$manifest" 2>/dev/null; then
  while read -r line; do
    [ -n "$line" ] && [ "${line:0:1}" != "#" ] || continue
    if ! grep -qxF -- "$line" "$manifest"; then
      echo "::error file=$manifest::$base records \"$line\", which this branch removes or changes. A recorded migration stays recorded; undo it with a new migration."
      status=1
    fi
  done < <(git show "$base:$manifest")
fi

while read -r sum file; do
  [ -n "$sum" ] && [ "${sum:0:1}" != "#" ] || continue
  version=${file%%_*}
  [[ "$version" > "$newest" ]] && newest=$version
  if [ ! -f "$dir/$file" ]; then
    if git cat-file -e "$base:$dir/$file" 2>/dev/null; then
      echo "::error file=$dir/$file::$file is applied to the project in $manifest and is on $base, but this branch deletes or renames it. Keep the file; undo it with a new migration."
      status=1
    fi
    continue
  fi
  if [ "$(sha256sum "$dir/$file" | cut -d' ' -f1)" != "$sum" ]; then
    echo "::error file=$dir/$file::$file is already applied to the project in $manifest but has changed since. Put the change in a new migration."
    status=1
  fi
done < "$manifest"

for path in "$dir"/*.sql; do
  file=$(basename "$path")
  grep -q " $file\$" "$manifest" && continue
  if [ $complete -eq 1 ]; then
    echo "::error file=$path::$file isn't recorded in $manifest. Record it there in a pull request before deploying (see the comment at the top of the file)."
    status=1
    continue
  fi
  version=${file%%_*}
  if [[ ! "$version" > "$newest" ]]; then
    echo "::error file=$path::$file isn't applied yet but is numbered at or below $newest, the newest migration the project has. Renumber it after $newest."
    status=1
  fi
done

[ $status -eq 0 ] && echo "Migrations agree with $manifest (newest applied: $newest)."
exit $status
