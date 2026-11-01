#!/usr/bin/env bash
# Install only inside the disposable container, never on the invoking host.
set -euo pipefail

if [[ $# -ne 6 ]]; then
  echo "Usage: $0 INITIAL.deb UPGRADE.deb amd64|arm64 INITIAL_VERSION UPGRADE_VERSION DIAGNOSTICS_DIRECTORY" >&2
  exit 2
fi
initial_package=$(cd "$(dirname "$1")" && pwd)/$(basename "$1")
upgrade_package=$(cd "$(dirname "$2")" && pwd)/$(basename "$2")
architecture=$3
initial_version=$4
upgrade_version=$5
diagnostics=$6
[[ -f "$initial_package" && -f "$upgrade_package" ]] || { echo 'Both candidate packages must exist.' >&2; exit 2; }
[[ "$architecture" == amd64 || "$architecture" == arm64 ]] || { echo 'Unsupported package architecture.' >&2; exit 2; }
[[ -n "$initial_version" && -n "$upgrade_version" && "$initial_version" != "$upgrade_version" ]] || { echo 'Two distinct expected package versions are required.' >&2; exit 2; }
native_architecture=$(docker info --format '{{.Architecture}}')
case "$native_architecture" in
  x86_64|amd64) native_architecture=amd64 ;;
  aarch64|arm64) native_architecture=arm64 ;;
esac
[[ "$native_architecture" == "$architecture" ]] || { echo "Expected native $architecture Docker engine, found $native_architecture." >&2; exit 2; }
mkdir -p "$diagnostics"
diagnostics=$(cd "$diagnostics" && pwd)
script_directory=$(cd "$(dirname "$0")" && pwd)
container="grate-deb-lifecycle-$$-$RANDOM"
cleanup() { docker rm -f "$container" >/dev/null 2>&1 || true; }
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# The pinned multi-architecture Ubuntu LTS image matches the native CI host. All installed
# packages and migration state disappear with this container; only logs survive.
docker run --rm --init --name "$container" --platform "linux/$architecture" \
  -e GRATE_DEB_LIFECYCLE_CONTAINER=1 \
  -v "$initial_package:/packages/initial.deb:ro" \
  -v "$upgrade_package:/packages/upgrade.deb:ro" \
  -v "$script_directory/Verify-PackageLifecycle.sh:/verification/verify.sh:ro" \
  -v "$diagnostics:/diagnostics" \
  ubuntu:24.04@sha256:fe81560990fae86dc4743202b2cb4d3df98d0bcf949173cecef15ce1127ef852 \
  timeout --kill-after=15s 8m bash /verification/verify.sh \
  "$architecture" "$initial_version" "$upgrade_version" 2>&1 | tee "$diagnostics/lifecycle.log"
