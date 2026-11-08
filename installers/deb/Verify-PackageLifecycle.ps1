#!/usr/bin/env pwsh
# Host-side assertions; every package/database command executes inside Docker.
param(
    [string]$Container,
    [string]$ContainerToken,
    [ValidateSet('amd64', 'arm64')][string]$Architecture,
    [string]$InitialVersion,
    [string]$UpgradeVersion,
    [string]$OutputDirectory
)

. "$PSScriptRoot/PackageLifecycle.Common.ps1"

function Test-PackageInstallation {
    param(
        [Parameter(Mandatory)][string]$Container,
        [Parameter(Mandatory)][string]$ContainerToken,
        [Parameter(Mandatory)][ValidateSet('amd64', 'arm64')][string]$Architecture,
        [Parameter(Mandatory)][string]$InitialVersion,
        [Parameter(Mandatory)][string]$UpgradeVersion,
        [Parameter(Mandatory)][string]$OutputDirectory
    )

    if ($Container -cnotmatch '\Agrate-deb-lifecycle-[a-f0-9]{32}\z' -or $ContainerToken -cnotmatch '\A[a-f0-9]{32}\z') {
        throw 'Use the disposable container created by Test-PackageLifecycle.ps1.'
    }
    $guard = Invoke-PackageTestDocker @('inspect', '--format', '{{index .Config.Labels "grate.deb-lifecycle"}}', $Container) 30
    if ($guard.TimedOut -or $guard.ExitCode -ne 0 -or $guard.Output.Trim() -cne $ContainerToken) {
        throw 'Container ownership does not match this package lifecycle test.'
    }

    $OutputDirectory = [IO.Path]::GetFullPath($OutputDirectory)
    $null = [IO.Directory]::CreateDirectory($OutputDirectory)
    $deadline = [DateTimeOffset]::UtcNow.AddMinutes(8)
    $work = '/tmp/grate-deb-lifecycle'
    $hostSql = Join-Path ([IO.Path]::GetTempPath()) ('grate-deb-sql-' + [Guid]::NewGuid().ToString('N'))
    $null = [IO.Directory]::CreateDirectory($hostSql)

    function Invoke-InContainer {
        param(
            [string[]]$Command,
            [int]$TimeoutSeconds = 45,
            [switch]$Capture,
            [switch]$AllowFailure
        )

        $remaining = [Math]::Floor(($deadline - [DateTimeOffset]::UtcNow).TotalSeconds)
        if ($remaining -le 0) {
            throw 'Package lifecycle exceeded its eight-minute limit.'
        }
        $seconds = [int][Math]::Min($remaining, $TimeoutSeconds)
        $arguments = @(
            'exec', '--env', 'DEBIAN_FRONTEND=noninteractive', $Container,
            'timeout', '--kill-after=5s', "${seconds}s"
        ) + $Command
        $result = Invoke-PackageTestDocker $arguments ($seconds + 10)
        if ($result.TimedOut) {
            throw "Container command '$($Command[0])' timed out."
        }
        if (!$AllowFailure -and $result.ExitCode -ne 0) {
            throw "Container command '$($Command[0])' failed ($($result.ExitCode)): $($result.ErrorOutput)$($result.Output)"
        }

        if ($AllowFailure) {
            return $result
        }
        if ($Capture) {
            return $result.Output.TrimEnd("`r", "`n")
        }
        if ($result.Output) {
            Write-Host $result.Output
        }
        if ($result.ErrorOutput) {
            Write-Host $result.ErrorOutput
        }
    }

    function Expect {
        param(
            [string]$Actual,
            [string]$Expected,
            [string]$Description
        )

        if ($Actual -cne $Expected) {
            throw "${Description}: expected '$Expected', got '$Actual'."
        }
    }

    function Test-RemotePath {
        param(
            [string]$Path,
            [string]$Kind = '-e'
        )

        (Invoke-InContainer @('test', $Kind, $Path) -AllowFailure).ExitCode -eq 0
    }

    function Get-ContainerGratePath {
        $search = Invoke-InContainer @('printenv', 'PATH') -Capture
        foreach ($directory in ($search -split ':')) {
            $candidate = $directory.TrimEnd('/') + '/grate'
            if ((Test-RemotePath $candidate '-f') -and (Test-RemotePath $candidate '-x')) {
                return $candidate
            }
        }

        return ''
    }

    function Check-Installation {
        param(
            [string]$Version,
            [string]$PackagePath
        )

        Expect (Invoke-InContainer @('dpkg-query', '-W', '-f=${Status}', 'grate') -Capture) 'install ok installed' 'Package status'
        Expect (Invoke-InContainer @('dpkg-query', '-W', '-f=${Version}', 'grate') -Capture) $Version 'Installed package version'
        Expect (Invoke-InContainer @('dpkg-query', '-W', '-f=${Architecture}', 'grate') -Capture) $Architecture 'Installed architecture'
        Expect (Get-ContainerGratePath) '/usr/bin/grate' 'Installed command path'

        $extracted = "$work/expected-$Version"
        Invoke-InContainer @('mkdir', '-p', $extracted)
        Invoke-InContainer @('dpkg-deb', '-x', $PackagePath, $extracted)
        Invoke-InContainer @('cmp', "$extracted/usr/bin/grate", '/usr/bin/grate')

        Invoke-InContainer @('/usr/bin/grate', '--help')
        Invoke-InContainer @('/usr/bin/grate', 'skills', 'install', '--local', '--path', "$work/skill")

        foreach ($skill in @('.agents', '.claude')) {
            if (!(Test-RemotePath "$work/skill/$skill/skills/use-grate/SKILL.md" '-s')) {
                throw 'Installed executable cannot install its bundled skill.'
            }
        }
    }

    function Migrate {
        param(
            [string]$Version
        )

        $arguments = @(
            '/usr/bin/grate', '--databasetype', 'sqlite',
            '--connectionstring', "Data Source=$work/database.db",
            '--files', "$work/sql", '--output', "$work/output",
            '--version', $Version, '--silent'
        )
        Invoke-InContainer $arguments
    }

    function Query {
        param(
            [string]$Sql
        )

        Invoke-InContainer @('sqlite3', "$work/database.db", $Sql) -Capture
    }

    function Check-Database {
        param(
            [string]$Rows,
            [string]$History
        )

        Expect (Query 'SELECT group_concat(id, ",") FROM (SELECT id FROM package_probe ORDER BY id);') $Rows 'Application data'
        Expect (Query 'SELECT COUNT(*) FROM grate_ScriptsRun;') $History 'Migration history count'
        Expect (Query 'SELECT COUNT(*) FROM grate_ScriptsRunErrors;') '0' 'Migration error history'
        $orphanedHistory = 'SELECT COUNT(*) FROM grate_ScriptsRun s LEFT JOIN grate_Version v ON v.id=s.version_id WHERE v.id IS NULL;'
        Expect (Query $orphanedHistory) '0' 'Orphaned migration history'
        Expect (Query 'SELECT COUNT(*) FROM grate_Version WHERE status <> "Finished";') '0' 'Unfinished migration versions'
    }

    function Write-Migration {
        param(
            [string]$Name,
            [string]$Sql
        )

        $path = Join-Path $hostSql $Name
        Set-Content -LiteralPath $path -Value ($Sql + "`n") -Encoding utf8NoBOM -NoNewline
        $result = Invoke-PackageTestDocker @('cp', $path, "${Container}:$work/sql/up/$Name") 30
        if ($result.TimedOut -or $result.ExitCode -ne 0) {
            throw "Cannot copy migration fixture $Name into test container."
        }
    }

    try {
        # Verify the disposable container and candidate metadata before installation.
        foreach ($path in @('/.dockerenv', '/packages/initial.deb', '/packages/upgrade.deb')) {
            if (!(Test-RemotePath $path '-f')) {
                throw "Missing lifecycle container fixture: $path"
            }
        }
        if (!(Test-RemotePath '/diagnostics' '-d')) {
            throw 'Missing lifecycle diagnostics mount.'
        }
        Expect (Invoke-InContainer @('printenv', 'GRATE_DEB_LIFECYCLE_CONTAINER') -Capture) '1' 'Disposable lifecycle marker'
        Expect (Invoke-InContainer @('dpkg', '--print-architecture') -Capture) $Architecture 'Container architecture'

        foreach ($package in @('initial', 'upgrade')) {
            Expect (Invoke-InContainer @('dpkg-deb', '-f', "/packages/$package.deb", 'Package') -Capture) 'grate' "$package package name"
            Expect (Invoke-InContainer @('dpkg-deb', '-f', "/packages/$package.deb", 'Architecture') -Capture) $Architecture "$package architecture"
        }
        Expect (Invoke-InContainer @('dpkg-deb', '-f', '/packages/initial.deb', 'Version') -Capture) $InitialVersion 'Initial artifact version'
        Expect (Invoke-InContainer @('dpkg-deb', '-f', '/packages/upgrade.deb', 'Version') -Capture) $UpgradeVersion 'Upgrade artifact version'
        Invoke-InContainer @('dpkg', '--compare-versions', $UpgradeVersion, 'gt', $InitialVersion)

        # Install the initial package, then prove that an unchanged rerun is skipped.
        Invoke-InContainer @('mkdir', '-p', "$work/sql/up", "$work/output", "$work/skill")
        Invoke-InContainer @('apt-get', 'update') 180
        Invoke-InContainer @('apt-get', 'install', '-y', '--no-install-recommends', 'sqlite3', '/packages/initial.deb') 180
        Check-Installation $InitialVersion '/packages/initial.deb'
        Write-Migration '001_create.sql' 'CREATE TABLE package_probe(id INTEGER PRIMARY KEY); INSERT INTO package_probe VALUES(42);'
        Migrate 'before-upgrade'
        Migrate 'before-upgrade'
        Check-Database '42' '1'
        Expect (Query 'SELECT script_name FROM grate_ScriptsRun;') '001_create.sql' 'Initial script identity'

        # Upgrade the package against the same database and apply the new script once.
        Write-Host "Upgrading package $InitialVersion -> $UpgradeVersion (the two test packages may contain identical candidate binary bytes)."
        Invoke-InContainer @('apt-get', 'install', '-y', '--no-install-recommends', '/packages/upgrade.deb') 180
        Check-Installation $UpgradeVersion '/packages/upgrade.deb'
        Check-Database '42' '1'
        Write-Migration '002_after_upgrade.sql' 'INSERT INTO package_probe VALUES(43);'
        Migrate 'after-upgrade'
        Migrate 'after-upgrade'
        Check-Database '42,43' '2'
        $scriptHistory = 'SELECT group_concat(script_name, ",") FROM (SELECT script_name FROM grate_ScriptsRun ORDER BY id);'
        $migrationVersions = 'SELECT group_concat(version, ",") FROM (SELECT version FROM grate_Version ORDER BY id);'
        Expect (Query $scriptHistory) '001_create.sql,002_after_upgrade.sql' 'Upgraded script history'
        Expect (Query $migrationVersions) 'before-upgrade,after-upgrade' 'Migration versions'

        # Removal/purge must remove package files while retaining user data.
        $packageFiles = @(foreach ($path in ((Invoke-InContainer @('dpkg-query', '-L', 'grate') -Capture) -split "`n")) {
            if ((Test-RemotePath $path '-f') -or (Test-RemotePath $path '-L')) {
                $path
            }
        })

        Invoke-InContainer @('apt-get', 'remove', '-y', 'grate') 180
        if (Test-RemotePath '/usr/bin/grate') {
            throw 'Removal left /usr/bin/grate behind.'
        }
        if (Get-ContainerGratePath) {
            throw 'Removal left grate on PATH.'
        }
        Check-Database '42,43' '2'

        Invoke-InContainer @('dpkg', '--purge', 'grate')
        if ((Invoke-InContainer @('dpkg-query', '-W', '-f=${Status}', 'grate') -AllowFailure).ExitCode -eq 0) {
            throw 'Purging left a package registration.'
        }
        foreach ($path in $packageFiles) {
            if ((Test-RemotePath $path) -or (Test-RemotePath $path '-L')) {
                throw "Purging left package-owned file $path."
            }
        }
        Check-Database '42,43' '2'
        if (!(Test-RemotePath "$work/skill/.agents/skills/use-grate/SKILL.md" '-s')) {
            throw 'Purging removed user skill data.'
        }

        Write-Host "PASS: $Architecture package install, upgrade $InitialVersion -> $UpgradeVersion, migrations/reruns, removal and purge."
    } finally {
        # Capture evidence before the wrapper removes its container. Failures here
        # are reported without hiding the original verification failure.
        try {
            $inventory = Invoke-PackageTestDocker @('exec', $Container, 'dpkg-query', '-W') 30
            $inventoryPath = Join-Path $OutputDirectory 'packages.txt'
            Set-Content -LiteralPath $inventoryPath -Value ($inventory.Output + $inventory.ErrorOutput) -Encoding utf8NoBOM -NoNewline

            $exists = Invoke-PackageTestDocker @('exec', $Container, 'test', '-f', "$work/database.db") 10
            if (!$exists.TimedOut -and $exists.ExitCode -eq 0) {
                $copy = Invoke-PackageTestDocker @('cp', "${Container}:$work/database.db", (Join-Path $OutputDirectory 'database.db')) 30
                if ($copy.TimedOut -or $copy.ExitCode -ne 0) {
                    Write-Warning 'Could not retain the lifecycle database.'
                }
            }
        } catch {
            Write-Warning "Could not capture lifecycle diagnostics: $_"
        }

        Remove-Item -LiteralPath $hostSql -Recurse -Force
    }
}

if ($MyInvocation.InvocationName -ne '.') {
    Test-PackageInstallation @PSBoundParameters
}
