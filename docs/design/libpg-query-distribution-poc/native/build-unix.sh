#!/usr/bin/env bash
set -euo pipefail
source_dir=${1:?Pass the pinned source checkout}
rid=${2:?Pass the target RID}
asset_root=${3:?Pass the external asset staging directory}
expected=c1546e7e97edc93fe8474d7a59881e91fbf48cfc
[[ $(git -C "$source_dir" rev-parse HEAD) == "$expected" ]]
case "$rid" in
  osx-arm64) architecture=arm64; library=libpg_query.dylib ;;
  osx-x64) architecture=x86_64; library=libpg_query.dylib ;;
  linux-arm64|linux-musl-arm64) architecture=aarch64; library=libpg_query.so ;;
  linux-x64|linux-musl-x64) architecture=x86_64; library=libpg_query.so ;;
  *) echo "Unsupported Unix RID $rid" >&2; exit 1 ;;
esac
build_dir=$(mktemp -d)
trap 'rm -rf "$build_dir"' EXIT
git -C "$source_dir" archive HEAD | tar -x -C "$build_dir"
if [[ "$rid" == osx-* ]]; then
  [[ $(uname -s) == Darwin ]]
  make -C "$build_dir" -j4 build_shared CC=clang \
    "CFLAGS=-arch $architecture -mmacosx-version-min=11.0" SONAME=@rpath/libpg_query.dylib
else
  [[ $(uname -s) == Linux && $(uname -m) == "$architecture" ]]
  if [[ "$rid" == linux-musl-* ]]; then
    libc_info=$(ldd --version 2>&1 || true)
    [[ "$libc_info" == *musl* ]]
  else
    getconf GNU_LIBC_VERSION
  fi
  make -C "$build_dir" -j4 build_shared SONAME=libpg_query.so LIBS='-lm -pthread' LDFLAGS=-Wl,-z,defs
fi
native_dir="$asset_root/runtimes/$rid/native"
mkdir -p "$native_dir" "$asset_root/licenses"
cp "$build_dir/$library" "$native_dir/$library"
cp "$build_dir/LICENSE" "$asset_root/licenses/libpg_query-LICENSE"
cp "$build_dir/src/postgres/COPYRIGHT" "$asset_root/licenses/PostgreSQL-COPYRIGHT"
cp "$build_dir/vendor/upb/LICENSE" "$asset_root/licenses/upb-LICENSE"
cp "$build_dir/vendor/upb/third_party/utf8_range/LICENSE" "$asset_root/licenses/utf8_range-LICENSE"
sed -n '1,/^ \*\//p' "$build_dir/vendor/xxhash/xxhash.h" > "$asset_root/licenses/xxhash-LICENSE"
file "$native_dir/$library"
if [[ "$rid" == osx-* ]]; then
  otool -L "$native_dir/$library"
else
  ldd "$native_dir/$library"
fi
