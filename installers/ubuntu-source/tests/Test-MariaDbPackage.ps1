#!/usr/bin/env pwsh
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$InitialPackage,
    [Parameter(Mandatory)]
    [string]$UpgradePackage,
    [Parameter(Mandatory)]
    [string]$OutputDirectory,
    [string]$RuntimeImage = 'grate-ubuntu-package-test:26.04',
    [string]$DatabaseImage = 'mariadb:10.4',
    [ValidateSet('arm64', 'amd64')]
    [string]$Architecture = 'arm64'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true
$output = [IO.Path]::GetFullPath($OutputDirectory)
if (Test-Path -LiteralPath $output) {
    throw 'Use a new output directory for isolated package and database state.'
}
New-Item -ItemType Directory -Path $output, "$output/packages", "$output/sql/up", "$output/user-project", "$output/output" | Out-Null
Copy-Item -LiteralPath $InitialPackage -Destination "$output/packages/initial.deb"
Copy-Item -LiteralPath $UpgradePackage -Destination "$output/packages/upgrade.deb"
'CREATE TABLE widgets (id INT PRIMARY KEY, name VARCHAR(100) NOT NULL) CHARACTER SET utf8mb4;
INSERT INTO widgets VALUES (1, ''Kildebygd Trøndelag'');' |
    Set-Content -LiteralPath "$output/sql/up/001_widgets.sql" -Encoding utf8NoBOM
'user data survives package removal' | Set-Content -LiteralPath "$output/user-project/keep.txt" -Encoding utf8NoBOM
$identity = [Guid]::NewGuid().ToString('N')
$network = "grate-deb-$identity"
$database = "grate-deb-db-$identity"
$application = "grate-deb-app-$identity"
$password = [Guid]::NewGuid().ToString('N')
$created = [Collections.Generic.List[string]]::new()
$networkCreated = $false
$passed = $false

function Invoke-DockerCheck {
    param(
        [string[]]$Arguments,
        [string]$LogName,
        [switch]$ExpectFailure
    )
    $previous = $PSNativeCommandUseErrorActionPreference
    $PSNativeCommandUseErrorActionPreference = $false
    try {
        $text = (& docker @Arguments 2>&1 | ForEach-Object { $_.ToString() }) -join "`n"
        $exitCode = $LASTEXITCODE
    }
    finally {
        $PSNativeCommandUseErrorActionPreference = $previous
    }
    $text = $text.Replace($password, '<redacted disposable credential>')
    $text | Set-Content -LiteralPath (Join-Path $output $LogName) -Encoding utf8
    if ((!$ExpectFailure -and $exitCode -ne 0) -or ($ExpectFailure -and $exitCode -eq 0)) {
        throw "Unexpected exit $exitCode for $LogName; inspect its log."
    }
    return $text
}

function Invoke-App {
    param(
        [string[]]$Command,
        [string]$LogName,
        [switch]$ExpectFailure
    )
    return Invoke-DockerCheck -Arguments (@('exec', $application, 'timeout', '120') + $Command) -LogName $LogName -ExpectFailure:$ExpectFailure
}

function Read-Database {
    param(
        [string]$Sql,
        [string]$LogName
    )
    $command = 'exec mysql --batch --skip-column-names --user="$MYSQL_USER" --password="$MYSQL_PASSWORD" "$MYSQL_DATABASE" --execute="$1"'
    return Invoke-DockerCheck -Arguments @('exec', $database, 'timeout', '30', 'sh', '-ec', $command, 'query', $Sql) -LogName $LogName
}

function Read-MigrationState {
    param(
        [string]$Name,
        [int]$ExpectedScripts
    )
    $state = [ordered]@{
        data = Read-Database 'SELECT id,HEX(name) FROM widgets ORDER BY id' "$Name-data.log"
        history = Read-Database "SELECT script_name,text_hash,version_id FROM grate_ScriptsRun WHERE script_name IN ('001_widgets.sql','002_upgrade.sql') ORDER BY script_name" "$Name-history.log"
        nonemptyHistory = Read-Database "SELECT COUNT(*) FROM grate_ScriptsRun WHERE script_name IN ('001_widgets.sql','002_upgrade.sql') AND LENGTH(text_hash)>0 AND version_id IS NOT NULL" "$Name-history-count.log"
        versions = Read-Database "SELECT COUNT(*) FROM grate_ScriptsRun s JOIN grate_Version v ON s.version_id=v.id WHERE s.script_name IN ('001_widgets.sql','002_upgrade.sql')" "$Name-version-links.log"
        versionValues = Read-Database "SELECT s.script_name,v.version FROM grate_ScriptsRun s JOIN grate_Version v ON s.version_id=v.id WHERE s.script_name IN ('001_widgets.sql','002_upgrade.sql') ORDER BY s.script_name" "$Name-version-values.log"
        errors = Read-Database 'SELECT COUNT(*) FROM grate_ScriptsRunErrors' "$Name-errors.log"
    }
    $expectedData = "1`t4B696C646562796764205472C3B86E64656C6167"
    $expectedVersions = "001_widgets.sql`t1.0.0"
    if ($ExpectedScripts -eq 2) {
        $expectedData += "`n2`t4F707067726164657274"
        $expectedVersions += "`n002_upgrade.sql`t2.0.0"
    }
    if ($state.data.Trim() -cne $expectedData -or $state.versionValues.Trim() -cne $expectedVersions -or $state.nonemptyHistory.Trim() -ne "$ExpectedScripts" -or $state.versions.Trim() -ne "$ExpectedScripts" -or $state.errors.Trim() -ne '0') {
        throw "Independent migration assertions failed for $Name."
    }
    $state | ConvertTo-Json | Set-Content -LiteralPath "$output/$Name.json" -Encoding utf8
    return ($state | ConvertTo-Json -Compress)
}

try {
    & docker image inspect --platform "linux/$Architecture" $RuntimeImage $DatabaseImage |
        Set-Content -LiteralPath "$output/images.json" -Encoding utf8
    & docker info --format '{{json .Architecture}}' |
        Set-Content -LiteralPath "$output/engine-architecture.json" -Encoding utf8
    & docker network create --internal --label "grate.package-test=$identity" $network | Out-Null
    $networkCreated = $true
    $databaseArguments = @(
        'run', '--detach', '--pull=never', '--platform', "linux/$Architecture",
        '--name', $database, '--label', "grate.package-test=$identity",
        '--network', $network, '--network-alias=db',
        '--env', 'MYSQL_DATABASE=package_probe', '--env', 'MYSQL_USER=package_probe',
        '--env', "MYSQL_PASSWORD=$password", '--env', "MYSQL_ROOT_PASSWORD=$password", $DatabaseImage
    )
    & docker @databaseArguments | Out-Null
    $created.Add($database)
    & docker run --detach --pull=never --platform "linux/$Architecture" --name $application --label "grate.package-test=$identity" --network $network --mount "type=bind,src=$output,dst=/work" --env DOTNET_BUNDLE_EXTRACT_BASE_DIR=/work/bundle $RuntimeImage | Out-Null
    $created.Add($application)
    $null = Invoke-App @('sh', '-ec', '! command -v dotnet; test ! -d /usr/share/dotnet; test ! -d /usr/lib/dotnet; dpkg-query -W') 'no-dotnet.log'
    $deadline = [DateTime]::UtcNow.AddSeconds(120)
    do {
        $PSNativeCommandUseErrorActionPreference = $false
        $null = & docker exec $database sh -ec 'mysql --user="$MYSQL_USER" --password="$MYSQL_PASSWORD" "$MYSQL_DATABASE" --execute="SELECT 1"' 2>$null
        $ready = $LASTEXITCODE -eq 0
        $PSNativeCommandUseErrorActionPreference = $true
        if (!$ready) {
            Start-Sleep -Milliseconds 500
        }
    } while (!$ready -and [DateTime]::UtcNow -lt $deadline)
    if (!$ready) {
        throw 'MariaDB fixture did not become ready within 120 seconds.'
    }
    $initialVersion = (Invoke-App @('dpkg-deb', '-f', '/work/packages/initial.deb', 'Version') 'initial-version.log').Trim()
    $upgradeVersion = (Invoke-App @('dpkg-deb', '-f', '/work/packages/upgrade.deb', 'Version') 'upgrade-version.log').Trim()
    $null = Invoke-App @('dpkg', '--compare-versions', $initialVersion, 'lt', $upgradeVersion) 'version-order.log'
    foreach ($packagePath in @('/work/packages/initial.deb', '/work/packages/upgrade.deb')) {
        $metadata = Invoke-App @('dpkg-deb', '-f', $packagePath, 'Package', 'Architecture') "metadata-$([IO.Path]::GetFileName($packagePath)).log"
        if ($metadata -notmatch 'Package: grate-mariadb' -or $metadata -notmatch "Architecture: $Architecture") {
            throw 'Unexpected package identity or architecture.'
        }
    }
    $null = Invoke-App @('dpkg', '-i', '/work/packages/initial.deb') 'install.log'
    $null = Invoke-App @('dpkg-deb', '-x', '/work/packages/initial.deb', '/work/expected-initial') 'extract-expected.log'
    $null = Invoke-App @('cmp', '/usr/bin/grate', '/work/expected-initial/usr/bin/grate') 'installed-payload.log'
    $help = Invoke-App @('/usr/bin/grate', '--help') 'help.log'
    if ($help -notmatch '\[default: MariaDB\]' -or $help -notmatch 'MariaDB only') {
        throw 'Installed help does not show the MariaDB-only default.'
    }
    if ($help -notmatch ('grate v' + [regex]::Escape($initialVersion.Split('-')[0]) + '\.0\s')) {
        throw 'The installed help banner does not show the intended PoC assembly version.'
    }
    $rejection = Invoke-App @('/usr/bin/grate', '--dbt', 'SQLite', '--connectionstring', 'Server=unreachable.invalid;') 'omitted-provider.log' -ExpectFailure
    if ($rejection -notmatch 'supports MariaDB only') {
        throw 'An omitted provider was not rejected by compiled-provider validation.'
    }
    $null = Invoke-App @('/usr/bin/grate', 'skills', 'install', '--local', '--path', '/work/user-project') 'skills.log'
    $null = Invoke-App @('sh', '-ec', 'test -s /work/user-project/.agents/skills/use-grate/SKILL.md; cmp /work/user-project/.agents/skills/use-grate/SKILL.md /work/user-project/.claude/skills/use-grate/SKILL.md') 'skill-content.log'
    $notices = Invoke-App @('cat', '/usr/share/doc/grate-mariadb/THIRD-PARTY-NOTICES.txt') 'installed-notices.txt'
    $manifestText = Invoke-App @('cat', '/usr/share/doc/grate-mariadb/dependency-licenses.json') 'installed-license-manifest.json'
    $inventory = @($manifestText | ConvertFrom-Json)
    foreach ($omitted in @('Oracle.ManagedDataAccess.Core', 'Microsoft.Data.SqlClient', 'Npgsql', 'Microsoft.Data.Sqlite', 'Microsoft.Identity.Client.NativeInterop')) {
        if ($inventory.id -contains $omitted) {
            throw "The MariaDB package closure unexpectedly contains $omitted."
        }
    }
    foreach ($component in @('Dapper', 'MySqlConnector', 'Microsoft.NETCore.App')) {
        if ($notices -notmatch [regex]::Escape($component) -or $manifestText -notmatch [regex]::Escape($component)) {
            throw "Installed licensing material omits $component."
        }
    }
    if ($notices -notmatch 'TERMS AND CONDITIONS FOR USE, REPRODUCTION, AND DISTRIBUTION') {
        throw 'The full Apache-2.0 terms are absent from installed notices.'
    }
    $migration = @(
        '/usr/bin/grate', '--connectionstring', "Server=db;Database=package_probe;User ID=package_probe;Password=$password;SslMode=None;",
        '--files', '/work/sql', '--output', '/work/output', '--silent', '--createdatabase=false', '--version', '1.0.0'
    )
    $null = Invoke-App $migration 'migration-first.log'
    $first = Read-MigrationState 'first' 1
    $null = Invoke-App ($migration + @('--databasetype', 'MariaDB')) 'migration-rerun.log'
    $second = Read-MigrationState 'rerun' 1
    if ($first -cne $second) {
        throw 'One-time script data/history changed on rerun.'
    }
    $null = Invoke-App @('dpkg', '-i', '/work/packages/upgrade.deb') 'upgrade.log'
    $registered = (Invoke-App @('dpkg-query', '-W', '-f=${Version}', 'grate-mariadb') 'registered-upgrade.log').Trim()
    if ($registered -cne $upgradeVersion) {
        throw 'The upgraded Debian version is not registered.'
    }
    $null = Invoke-App @('dpkg-deb', '-x', '/work/packages/upgrade.deb', '/work/expected-upgrade') 'extract-upgrade.log'
    $null = Invoke-App @('cmp', '/usr/bin/grate', '/work/expected-upgrade/usr/bin/grate') 'upgraded-payload.log'
    $upgradedHelp = Invoke-App @('/usr/bin/grate', '--help') 'upgraded-executable-version.log'
    if ($upgradedHelp -notmatch ('grate v' + [regex]::Escape($upgradeVersion.Split('-')[0]) + '\.0\s')) {
        throw 'The upgraded executable version does not match its intended PoC source version.'
    }
    "INSERT INTO widgets VALUES (2, 'Oppgradert');" | Set-Content -LiteralPath "$output/sql/up/002_upgrade.sql" -Encoding utf8NoBOM
    $migration[-1] = '2.0.0'
    $null = Invoke-App $migration 'migration-upgrade.log'
    $upgraded = Read-MigrationState 'upgraded' 2

    # This fixture tests package-manager identity/ownership only, not SQLite.
    New-Item -ItemType Directory -Path "$output/conflict/DEBIAN", "$output/conflict/usr/bin" | Out-Null
    "Package: grate-sqlite`nVersion: 0.0.1`nArchitecture: $Architecture`nMaintainer: Fixture <fixture@example.invalid>`nConflicts: grate-mariadb`nDescription: Metadata-only variant conflict fixture`n" |
        Set-Content -LiteralPath "$output/conflict/DEBIAN/control" -Encoding utf8NoBOM
    $null = Invoke-App @('cp', '/bin/true', '/work/conflict/usr/bin/grate') 'fixture-payload.log'
    $null = Invoke-App @('dpkg-deb', '--root-owner-group', '--build', '/work/conflict', '/work/packages/conflict.deb') 'fixture-build.log'
    $null = Invoke-App @('dpkg', '-i', '/work/packages/conflict.deb') 'conflict-rejected.log' -ExpectFailure
    $null = Invoke-App @('/usr/bin/grate', '--help') 'after-conflict-help.log'
    if ((Read-MigrationState 'after-conflict' 2) -cne $upgraded) {
        throw 'A conflicting package attempt changed migration state.'
    }
    $null = Invoke-App @('dpkg', '--remove', 'grate-mariadb') 'remove-for-switch.log'
    $null = Invoke-App @('test', '!', '-e', '/usr/bin/grate') 'removed-command.log'
    $null = Invoke-App @('dpkg', '-i', '/work/packages/conflict.deb') 'fixture-switch-install.log'
    $null = Invoke-App @('/usr/bin/grate') 'fixture-command.log'
    $null = Invoke-App @('dpkg', '--purge', 'grate-sqlite') 'fixture-switch-purge.log'
    $null = Invoke-App @('dpkg', '-i', '/work/packages/upgrade.deb') 'switch-back.log'
    $null = Invoke-App $migration 'migration-after-switch.log'
    if ((Read-MigrationState 'after-switch' 2) -cne $upgraded) {
        throw 'Variant switching/rerun changed existing data/history.'
    }
    $null = Invoke-App @('sh', '-ec', 'file /usr/bin/grate; ldd /usr/bin/grate; if [ -d /work/bundle ]; then find /work/bundle -type f -name "*.so" -exec ldd {} \; ; fi') 'native-closure.log'
    $nativeClosure = Get-Content -LiteralPath "$output/native-closure.log" -Raw
    if ([string]::IsNullOrWhiteSpace($nativeClosure) -or $nativeClosure -match 'not found') {
        throw 'An extracted native library has an unresolved ELF dependency.'
    }
    $null = Invoke-App @('dpkg', '--purge', 'grate-mariadb') 'purge.log'
    $null = Invoke-App @('sh', '-ec', 'test ! -e /usr/bin/grate; test ! -d /usr/share/doc/grate-mariadb; test ! -f /usr/share/man/man1/grate.1.gz; test -s /work/user-project/keep.txt; test -s /work/user-project/.agents/skills/use-grate/SKILL.md; test -s /work/sql/up/001_widgets.sql; test -d /work/output') 'retained-user-data.log'
    if ((Read-MigrationState 'after-purge' 2) -cne $upgraded) {
        throw 'Package purge changed the external migration database.'
    }
    $passed = $true
}
finally {
    $PSNativeCommandUseErrorActionPreference = $false
    if ($created.Contains($application)) {
        & docker logs $application 2>&1 | Set-Content -LiteralPath "$output/runtime-container.log" -Encoding utf8
    }
    if ($created.Contains($database)) {
        & docker logs $database 2>&1 | Set-Content -LiteralPath "$output/database.log" -Encoding utf8
    }
    foreach ($container in $created) {
        & docker rm --force --volumes $container | Out-Null
    }
    if ($networkCreated) {
        & docker network rm $network | Out-Null
    }
    $PSNativeCommandUseErrorActionPreference = $true
    [ordered]@{
        passed = $passed
        architecture = $Architecture
        packageInputs = @(Get-FileHash -LiteralPath "$output/packages/initial.deb", "$output/packages/upgrade.deb" -Algorithm SHA256 | Select-Object Path, Hash)
        scope = 'Installed self-contained MariaDB packages; conflict/switch package is a metadata-only fixture, not a SQLite implementation'
    } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath "$output/result.json" -Encoding utf8
}
