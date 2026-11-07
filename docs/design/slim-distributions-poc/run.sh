#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/../../.."
output="${1:-artifacts/slim-poc}"
if [[ -e "$output" ]]; then
  echo "Use a fresh repository-relative output directory." >&2
  exit 1
fi

prefix="grate-slim-poc-$$"
sqlserver="$prefix-sqlserver"
mariadb="$prefix-mariadb"
sdk="$prefix-sdk"
password="Grate_PoC_$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')"
cleanup() {
  docker stop "$sdk" "$sqlserver" "$mariadb" >/dev/null 2>&1 || true
  docker network rm "$prefix" >/dev/null 2>&1 || true
}
trap cleanup EXIT

docker network create "$prefix" >/dev/null
docker run -d --rm --name "$sqlserver" --network "$prefix" --platform linux/amd64 \
  -e ACCEPT_EULA=Y -e MSSQL_SA_PASSWORD="$password" -e MSSQL_MEMORY_LIMIT_MB=2048 \
  mcr.microsoft.com/mssql/server:2022-latest@sha256:4402d880dd4c34bfa7d8705e56a86cd6c88da80a1f6bbbe741f999e76264a090 >/dev/null
docker run -d --rm --name "$mariadb" --network "$prefix" \
  -e MYSQL_ROOT_PASSWORD="$password" \
  mariadb:10.4@sha256:22edfe1c78349f8cae88bbb5c2873b7e6c515be767c91c691308ce57445806f3 >/dev/null

for attempt in {1..90}; do
  if docker exec "$sqlserver" sh -c 'SQLCMDPASSWORD="$MSSQL_SA_PASSWORD" /opt/mssql-tools18/bin/sqlcmd -S localhost -U sa -C -l 2 -t 2 -Q "SELECT 1" -b' >/dev/null 2>&1 &&
     docker exec "$mariadb" sh -c 'MYSQL_PWD="$MYSQL_ROOT_PASSWORD" mysqladmin ping -uroot --silent --connect-timeout=2' >/dev/null 2>&1; then
    break
  fi
  if [[ "$attempt" == 90 ]]; then
    echo "Disposable databases did not become ready within 90 readiness checks." >&2
    exit 1
  fi
  sleep 2
done

docker run --rm --name "$sdk" --network "$prefix" --platform linux/amd64 \
  -v "$PWD:/src" -w /src \
  -e "GRATE_POC_SQLSERVER=Server=$sqlserver;Database={database};User ID=sa;Password=$password;TrustServerCertificate=true;Encrypt=true" \
  -e "GRATE_POC_MARIADB=Server=$mariadb;Database={database};User ID=root;Password=$password" \
  mcr.microsoft.com/dotnet/sdk:11.0.100-rc.3@sha256:59d092a889fbad09c1a0b0c5dd072c6315125b0294a5cddfa48ec892f63b2ab3 \
  sh -c 'apt-get update -qq && apt-get install -y -qq python3 &&
    python3 docs/design/slim-distributions-poc/verify.py --output "/src/$1"' sh "$output"
