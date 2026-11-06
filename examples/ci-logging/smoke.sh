#!/usr/bin/env bash
# Run with a grate executable from this checkout. Leave the runner environment intact.
set -euo pipefail
if (( $# == 0 )); then
    echo "Usage: bash $0 <grate executable> [command arguments...]" >&2
    exit 2
fi

scratch=$(mktemp -d)
trap 'rm -rf -- "$scratch"' EXIT
mkdir -p "$scratch/sql/up"
options=(--databasetype=sqlite "--connectionstring=Data Source=$scratch/example.db"
         "--files=$scratch/sql" "--output=$scratch/output" --silent)

printf '%s\n' 'CREATE TABLE example (id INTEGER);' > "$scratch/sql/up/01-create.sql"
"$@" "${options[@]}" --transaction

printf '%s\n' 'SELECT * FROM missing_table;' > "$scratch/sql/up/02-failure.sql"
status=0
"$@" "${options[@]}" || status=$?
if (( status != 1 )); then
    echo "Expected exit code 1 from the failing SQLite migration, got $status" >&2
    exit 1
fi
