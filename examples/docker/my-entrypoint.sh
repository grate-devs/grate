#!/bin/sh
set -eu

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
--warnandignoreononetimescriptchanges=${WARNANDIGNOREONETIMESCRIPTCHANGES:-true} \
--verbosity=${VERBOSITY:-Trace} \
"$@"
