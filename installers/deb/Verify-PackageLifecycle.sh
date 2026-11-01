#!/usr/bin/env bash
# Container-side assertions. Test-PackageLifecycle.sh is the public entry point.
set -euo pipefail
[[ -f /.dockerenv && "${GRATE_DEB_LIFECYCLE_CONTAINER:-}" == 1 && -f /packages/initial.deb && -f /packages/upgrade.deb && -d /diagnostics ]] || {
  echo 'This verifier runs only in the disposable container created by Test-PackageLifecycle.sh.' >&2
  exit 2
}
architecture=$1
initial_version=$2
upgrade_version=$3
work=/tmp/grate-deb-lifecycle
mkdir -p "$work/sql/up" "$work/output" "$work/skill" /diagnostics
diagnostics() {
  result=$?
  trap - EXIT
  dpkg-query -W > /diagnostics/packages.txt || true
  if [[ -f "$work/database.db" ]]; then cp "$work/database.db" /diagnostics/database.db; fi
  exit "$result"
}
trap diagnostics EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
expect() { [[ "$1" == "$2" ]] || fail "$3: expected '$2', got '$1'"; }
expect "$(dpkg --print-architecture)" "$architecture" 'Container architecture'
for package in initial upgrade; do
  expect "$(dpkg-deb -f "/packages/$package.deb" Package)" grate "$package package name"
  expect "$(dpkg-deb -f "/packages/$package.deb" Architecture)" "$architecture" "$package architecture"
done
expect "$(dpkg-deb -f /packages/initial.deb Version)" "$initial_version" 'Initial artifact version'
expect "$(dpkg-deb -f /packages/upgrade.deb Version)" "$upgrade_version" 'Upgrade artifact version'
dpkg --compare-versions "$upgrade_version" gt "$initial_version" || fail 'Upgrade version must be greater than initial version.'

export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y --no-install-recommends sqlite3 /packages/initial.deb

check_installation() {
  local package_version=$1 package_path=$2
  expect "$(dpkg-query -W -f='${Status}' grate)" 'install ok installed' 'Package status'
  expect "$(dpkg-query -W -f='${Version}' grate)" "$package_version" 'Installed package version'
  expect "$(dpkg-query -W -f='${Architecture}' grate)" "$architecture" 'Installed architecture'
  expect "$(command -v grate)" /usr/bin/grate 'Installed command path'
  [[ -x /usr/bin/grate ]] || fail 'Installed executable is missing or not executable.'
  local extracted="$work/expected-$package_version"
  mkdir -p "$extracted"
  dpkg-deb -x "$package_path" "$extracted"
  cmp "$extracted/usr/bin/grate" /usr/bin/grate || fail 'Installed payload differs from the candidate package.'
  timeout 45s /usr/bin/grate --help
  timeout 45s /usr/bin/grate skills install --local --path "$work/skill"
  [[ -s "$work/skill/.agents/skills/use-grate/SKILL.md" && -s "$work/skill/.claude/skills/use-grate/SKILL.md" ]] || fail 'Installed executable cannot install its bundled skill.'
}
migrate() {
  timeout 45s /usr/bin/grate --databasetype sqlite --connectionstring "Data Source=$work/database.db" \
    --files "$work/sql" --output "$work/output" --version "$1" --silent
}
query() { sqlite3 "$work/database.db" "$1"; }
check_database() {
  local expected_rows=$1 expected_history=$2
  expect "$(query 'SELECT group_concat(id, ",") FROM (SELECT id FROM package_probe ORDER BY id);')" "$expected_rows" 'Application data'
  expect "$(query 'SELECT COUNT(*) FROM grate_ScriptsRun;')" "$expected_history" 'Migration history count'
  expect "$(query 'SELECT COUNT(*) FROM grate_ScriptsRunErrors;')" 0 'Migration error history'
  expect "$(query 'SELECT COUNT(*) FROM grate_ScriptsRun s LEFT JOIN grate_Version v ON v.id=s.version_id WHERE v.id IS NULL;')" 0 'Orphaned migration history'
  expect "$(query 'SELECT COUNT(*) FROM grate_Version WHERE status <> "Finished";')" 0 'Unfinished migration versions'
}

check_installation "$initial_version" /packages/initial.deb
printf '%s\n' 'CREATE TABLE package_probe(id INTEGER PRIMARY KEY); INSERT INTO package_probe VALUES(42);' > "$work/sql/up/001_create.sql"
migrate before-upgrade
migrate before-upgrade
check_database 42 1
expect "$(query 'SELECT script_name FROM grate_ScriptsRun;')" 001_create.sql 'Initial script identity'

echo "Upgrading package $initial_version -> $upgrade_version (the two test packages may contain identical candidate binary bytes)."
apt-get install -y --no-install-recommends /packages/upgrade.deb
check_installation "$upgrade_version" /packages/upgrade.deb
check_database 42 1
printf '%s\n' 'INSERT INTO package_probe VALUES(43);' > "$work/sql/up/002_after_upgrade.sql"
migrate after-upgrade
migrate after-upgrade
check_database 42,43 2
expect "$(query 'SELECT group_concat(script_name, ",") FROM (SELECT script_name FROM grate_ScriptsRun ORDER BY id);')" 001_create.sql,002_after_upgrade.sql 'Upgraded script history'
expect "$(query 'SELECT group_concat(version, ",") FROM (SELECT version FROM grate_Version ORDER BY id);')" before-upgrade,after-upgrade 'Migration versions'

# Snapshot only package-owned regular files/symlinks; shared directories such as
# /usr/bin must remain after removal. The migration database is application data.
while IFS= read -r path; do
  if [[ -f "$path" || -L "$path" ]]; then printf '%s\n' "$path"; fi
done < <(dpkg-query -L grate) > "$work/package-files.txt"
apt-get remove -y grate
hash -r
[[ ! -e /usr/bin/grate ]] || fail 'Removal left /usr/bin/grate behind.'
if command -v grate; then fail 'Removal left grate on PATH.'; fi
check_database 42,43 2
dpkg --purge grate
if dpkg-query -W -f='${Status}' grate 2>/dev/null; then fail 'Purging left a package registration.'; fi
while IFS= read -r path; do
  [[ ! -e "$path" && ! -L "$path" ]] || fail "Purging left package-owned file $path."
done < "$work/package-files.txt"
check_database 42,43 2
[[ -s "$work/skill/.agents/skills/use-grate/SKILL.md" ]] || fail 'Purging removed user skill data.'
printf 'PASS: %s package install, upgrade %s -> %s, migrations/reruns, removal and purge.\n' "$architecture" "$initial_version" "$upgrade_version"
