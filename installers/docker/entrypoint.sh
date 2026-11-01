#!/bin/sh
set -eu

# Entrypoint for the grate Docker image.
#
# grate's arguments are built here so the shell can expand environment variables
# and apply defaults before grate runs. Configure a container via these vars:
#
#   APP_CONNSTRING   (required) Connection string for the target database.
#                    Injected at runtime as a secret/env var - do not bake into the image.
#                    Unset -> the container fails fast (set -u).
#   VERSION          (default 1.0.0)     Database version for this migration.
#   DATABASE_TYPE    (default sqlserver) Target database: sqlserver, postgresql, mariadb, oracle, sqlite.
#   CREATE_DATABASE  (default true)      Create the database if it does not exist.
#   ENVIRONMENT      (default LOCAL)     grate environment name for environment-aware scripts.
#   TRANSACTION      (default false)     Run the migration inside a transaction.
#
# SQL scripts are read from /db and migration output is written to /output.
# Any extra arguments passed to `docker run` are forwarded to grate ("$@").
exec ./grate \
--sqlfilesdirectory=/db \
--version=${VERSION:-1.0.0} \
--connstring="$APP_CONNSTRING" \
--databasetype=${DATABASE_TYPE:-sqlserver} \
--silent \
--outputPath=/output \
--createdatabase=${CREATE_DATABASE:-true} \
--environment=${ENVIRONMENT:-LOCAL} \
--transaction=${TRANSACTION:-false} \
"$@"
