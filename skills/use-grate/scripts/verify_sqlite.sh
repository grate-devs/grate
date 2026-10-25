#!/bin/sh
# 77 means verification was skipped, not passed.
script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd) || exit 1
sdk_version=$(dotnet --version 2>/dev/null) || sdk_version=
sdk_major=${sdk_version%%.*}
case "$sdk_major" in
    ''|*[!0-9]*) sdk_major=0 ;;
esac
if [ "$sdk_major" -lt 10 ]; then
    echo 'SKIP: SQLite verification needs .NET SDK 10 or newer. grate and the skill can still be used without it.' >&2
    exit 77
fi
exec dotnet run --file "$script_dir/verify_sqlite.cs" -- "$@"
