$ErrorActionPreference = 'Stop'
. "$PSScriptRoot/release_common.ps1"
. "$PSScriptRoot/distribution_profiles.ps1"

function Assert-WindowsChannelReleaseContext {
    param(
        $Run,
        $Release,
        [string]$TagCommit,
        [string]$Version
    )

    if ($Version -cnotmatch '\A(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\z') {
        throw 'A stable three-part release version is required.'
    }
    if ($Run.path -cne '.github/workflows/build.yml' -or $Run.event -cne 'release' -or $Run.status -cne 'completed' -or $Run.conclusion -cne 'success' -or
        $Run.repository.full_name -cne 'grate-devs/grate' -or $Run.head_repository.full_name -cne 'grate-devs/grate' -or $Run.head_branch -cne $Version -or
        $TagCommit -cnotmatch '\A[a-f0-9]{40}\z' -or $Run.head_sha -cne $TagCommit -or
        $Release.tag_name -cne $Version -or $Release.draft -or $Release.prerelease -or !$Release.published_at) {
        throw 'The successful original release run, stable public release and immutable tag must agree.'
    }
}

function Get-WindowsChannelReleaseContext {
    param(
        [string]$Version,
        [string]$ReleaseRunId
    )

    if ($ReleaseRunId -cnotmatch '\A[1-9][0-9]*\z') {
        throw 'A numeric original release run ID is required.'
    }
    $headers = @{ Accept = 'application/vnd.github+json' }
    if ($env:GH_TOKEN) {
        $headers.Authorization = "Bearer $env:GH_TOKEN"
    }
    $api = 'https://api.github.com/repos/grate-devs/grate'
    $run = Invoke-RestMethod "$api/actions/runs/$ReleaseRunId" -Headers $headers
    $release = Invoke-RestMethod "$api/releases/tags/$Version" -Headers $headers
    $tag = Invoke-RestMethod "$api/git/ref/tags/$Version" -Headers $headers
    while ($tag.object.type -ceq 'tag') {
        $tag = Invoke-RestMethod "$api/git/tags/$($tag.object.sha)" -Headers $headers
    }
    Assert-WindowsChannelReleaseContext -Run $run -Release $release -TagCommit $tag.object.sha -Version $Version
    $source = Invoke-RestMethod "$api/contents/Directory.Packages.props?ref=$($tag.object.sha)" -Headers $headers
    $centralPackages = ConvertFrom-WindowsChannelCentralPackagesBase64 -Content $source.content
    $sqlite = Resolve-WindowsChannelSQLitePolicy -CentralPackages $centralPackages -ReadBundleNuspec {
        param(
            $bundleVersion
        )
        (Invoke-WebRequest -Uri "https://api.nuget.org/v3-flatcontainer/sqlitepclraw.bundle_e_sqlite3/$bundleVersion/sqlitepclraw.bundle_e_sqlite3.nuspec" -TimeoutSec 60).Content
    }
    [pscustomobject]@{
        Version = $Version
        RunId = $ReleaseRunId
        SourceCommit = $tag.object.sha
        Release = $release
        ExpectedSQLiteVersion = $sqlite.ExpectedSQLiteVersion
        SQLiteBundleVersion = $sqlite.SQLiteBundleVersion
        SQLiteNativePackageId = $sqlite.SQLiteNativePackageId
    }
}

function Save-WindowsChannelReleaseAsset {
    param(
        $Context,
        [string]$Name,
        [string]$Directory
    )

    $asset = @($Context.Release.assets | Where-Object name -CEQ $Name)
    $expectedUrl = "https://github.com/grate-devs/grate/releases/download/$($Context.Version)/$Name"
    if ($asset.Count -ne 1 -or $asset[0].browser_download_url -cne $expectedUrl -or
        $asset[0].digest -cnotmatch '\Asha256:[a-f0-9]{64}\z') {
        throw "Missing or unexpected immutable release asset: $Name"
    }
    New-Item -ItemType Directory -Path $Directory -Force | Out-Null
    $path = Join-Path $Directory $Name
    Invoke-WebRequest -Uri $expectedUrl -OutFile $path
    if ('sha256:' + (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant() -cne $asset[0].digest -or
        (Get-Item -LiteralPath $path).Length -ne $asset[0].size) {
        throw "Downloaded release asset bytes differ: $Name"
    }
    $path
}

function Invoke-WindowsChannelCommand {
    param(
        [string]$FilePath,
        [string[]]$Arguments,
        [string]$Log,
        [int]$TimeoutSeconds = 600
    )

    $result = Invoke-ReleaseProcess -FilePath $FilePath -Arguments $Arguments -TimeoutSeconds $TimeoutSeconds
    ($result.Text + $result.ErrorText) | Set-Content -LiteralPath $Log -Encoding utf8NoBOM
    if ($result.ExitCode -ne 0) {
        throw "Channel verification command failed with exit $($result.ExitCode); see $Log."
    }
}

function Test-WindowsChannelExecutable {
    param(
        [string]$Executable,
        [string]$ExpectedExecutable,
        [string]$Distribution,
        [string]$Version,
        [string]$OutputDirectory,
        [string]$ExpectedSQLiteVersion
    )

    if (!(Test-Path -LiteralPath $Executable) -or
        (Get-FileHash -LiteralPath $Executable -Algorithm SHA256).Hash -cne
        (Get-FileHash -LiteralPath $ExpectedExecutable -Algorithm SHA256).Hash) {
        throw 'Installed executable differs from the exact public release payload.'
    }
    . "$PSScriptRoot/../../installers/chocolatey/Package.Common.ps1"
    $metadata = [Diagnostics.FileVersionInfo]::GetVersionInfo($Executable)
    Assert-ChocolateyPayloadIdentity -ProductName $metadata.ProductName -ProductVersion $metadata.ProductVersion -Distribution $Distribution -Version $Version
    Invoke-WindowsChannelCommand -FilePath $Executable -Arguments @('--help') -Log "$OutputDirectory/help.log"
    Invoke-WindowsChannelCommand -FilePath $Executable -Arguments @('skills', 'install', '--local', '--path', "$OutputDirectory/skill") -Log "$OutputDirectory/skill.log"
    if (!(Test-Path -LiteralPath "$OutputDirectory/skill/.agents/skills/use-grate/SKILL.md")) {
        throw 'Installed executable did not provide its bundled skill.'
    }
    if ($Distribution -in @('All', 'SQLite')) {
        if ($ExpectedSQLiteVersion -cnotmatch '\A(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\z') {
            throw 'An exact source-resolved numeric SQLite version is required before generating probe SQL.'
        }
        New-Item -ItemType Directory -Path "$OutputDirectory/sql/up", "$OutputDirectory/sql/afterMigration" -Force | Out-Null
        "CREATE TABLE channel_probe(native_version TEXT CHECK(native_version = '$ExpectedSQLiteVersion')); INSERT INTO channel_probe SELECT sqlite_version();" |
            Set-Content -LiteralPath "$OutputDirectory/sql/up/001_probe.sql" -Encoding utf8NoBOM
        "CREATE TEMP TABLE channel_assert(value INTEGER CHECK(value = 1)); INSERT INTO channel_assert SELECT COUNT(*) FROM channel_probe; INSERT INTO channel_assert SELECT COUNT(*) FROM grate_ScriptsRun WHERE script_name='001_probe.sql'; INSERT INTO channel_assert SELECT CASE WHEN COUNT(*)=0 THEN 1 ELSE 0 END FROM grate_ScriptsRunErrors;" |
            Set-Content -LiteralPath "$OutputDirectory/sql/afterMigration/001_assert.sql" -Encoding utf8NoBOM
        $arguments = @('--connectionstring', "Data Source=$OutputDirectory/probe.db", '--files', "$OutputDirectory/sql", '--output', "$OutputDirectory/migrations", '--silent')
        if ($Distribution -eq 'All') {
            $arguments += '--databasetype', 'sqlite'
        }
        foreach ($attempt in 1..2) {
            Invoke-WindowsChannelCommand -FilePath $Executable -Arguments $arguments -Log "$OutputDirectory/migrate-$attempt.log"
        }
    }
}

function Assert-WindowsChannelEvidence {
    param(
        [object[]]$Records,
        [string]$Version,
        [string]$ReleaseRunId,
        [string]$SourceCommit,
        [string]$ValidationRunId,
        [string]$ExpectedSQLiteVersion
    )

    $expected = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($profile in @('All', 'SQLite', 'SQLServer', 'MariaDB', 'PostgreSQL', 'Oracle')) {
        foreach ($case in @('zip/x86', 'zip/x64', 'zip/arm64', 'wix/x64', 'wix/arm64')) {
            [void]$expected.Add("winget/$profile/$case")
        }
        [void]$expected.Add("chocolatey/$profile/zip/x64")
    }
    if ($Records.Count -ne 36 -or $ValidationRunId -cnotmatch '\A[1-9][0-9]*\z') {
        throw 'All 36 native channel records and a numeric validation run identity are required.'
    }
    foreach ($record in $Records) {
        $key = "$($record.Channel)/$($record.Distribution)/$($record.InstallerType)/$($record.Architecture)"
        if (!$expected.Remove($key) -or $record.Status -cne 'passed' -or $record.Version -cne $Version -or
            $record.ReleaseRunId -cne $ReleaseRunId -or $record.SourceCommit -cne $SourceCommit -or
            $record.ValidationRunId -cne $ValidationRunId -or
            $record.ExpectedSQLiteVersion -cnotmatch '\A(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\z' -or
            ($ExpectedSQLiteVersion -and $record.ExpectedSQLiteVersion -cne $ExpectedSQLiteVersion) -or
            ($record.Channel -ceq 'chocolatey' -and $record.Distribution -ceq 'All' -and $record.ChocolateyAllUpgrade -cne 'passed') -or
            ($record.Channel -ceq 'winget' -and $record.Distribution -ceq 'All' -and
            $record.LegacyMigration -cne 'passed; actual public 2.0.0 to final release through private PreIndexed source')) {
            throw "Duplicate, incorrect-source or non-passing channel record: $key"
        }
    }
    if ($expected.Count -ne 0) {
        throw 'Missing native channel coverage.'
    }
}

function Get-WindowsChannelUninstallArguments {
    param(
        [Parameter(Mandatory)][ValidateSet('zip', 'wix')][string]$InstallerType,
        [Parameter(Mandatory)][string]$ManifestDirectory,
        [string]$PortableProductCode
    )

    $identity = @('--manifest', $ManifestDirectory)
    if ($InstallerType -eq 'zip') {
        if ([string]::IsNullOrWhiteSpace($PortableProductCode)) {
            throw 'The exact installed portable registration is required for uninstall.'
        }
        $identity = @('--product-code', $PortableProductCode)
    }
    # WinGet may consult configured sources while resolving a local installation.
    # Noninteractive uninstall must carry the same source-agreement opt-in as install.
    @('uninstall') + $identity + @('--silent', '--disable-interactivity', '--accept-source-agreements')
}

function Resolve-WindowsChannelSQLitePolicy {
    param(
        [Parameter(Mandatory)][xml]$CentralPackages,
        [Parameter(Mandatory)][scriptblock]$ReadBundleNuspec
    )

    $native = @($CentralPackages.SelectNodes("//*[local-name()='PackageVersion' and @Include='SQLite']"))
    $bundle = @($CentralPackages.SelectNodes("//*[local-name()='PackageVersion' and @Include='SQLitePCLRaw.bundle_e_sqlite3']"))
    $bundleVersion = $null
    if ($native.Count -eq 1) {
        $nativeVersion = [string]$native[0].Version
    } elseif ($native.Count -eq 0 -and $bundle.Count -eq 1) {
        $bundleVersion = [string]$bundle[0].Version
        if ($bundleVersion -cnotmatch '\A(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\z') {
            throw 'The exact source must pin one stable SQLite bundle version.'
        }
        [xml]$nuspec = & $ReadBundleNuspec $bundleVersion
        if ([string]$nuspec.package.metadata.id -cne 'SQLitePCLRaw.bundle_e_sqlite3' -or
            [string]$nuspec.package.metadata.version -cne $bundleVersion) {
            throw 'The immutable SQLite bundle metadata does not match the source package pin.'
        }
        $versions = @($nuspec.SelectNodes("//*[local-name()='dependency' and @id='SQLite']") | ForEach-Object { [string]$_.version } | Sort-Object -Unique)
        if ($versions.Count -ne 1) {
            throw 'The source-pinned bundle must select one unambiguous SQLite native package version.'
        }
        $nativeVersion = $versions[0]
    } else {
        throw 'Cannot derive one exact native SQLite package from the selected release source.'
    }
    # Only a numeric native version may enter SQL. Do not parse a source comment,
    # guess from the managed wrapper version, or use the workflow branch pin.
    if ($nativeVersion -cnotmatch '\A(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\z') {
        throw 'The source-resolved native SQLite version must be a three-part numeric version.'
    }
    [pscustomobject]@{
        ExpectedSQLiteVersion = $nativeVersion
        SQLiteBundleVersion = $bundleVersion
        SQLiteNativePackageId = 'SQLite'
    }
}

function Select-WindowsChannelChocolateyBaseline {
    param(
        [Parameter(Mandatory)][object[]]$Entries,
        [Parameter(Mandatory)][string]$Version
    )

    $eligible = @($Entries | Where-Object {
        $_.Id -ceq 'grate' -and $_.Approved -and $_.Version -cmatch '\A(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\z' -and
        [version]$_.Version -lt [version]$Version
    } | Sort-Object { [version]$_.Version } -Descending)
    if (!$eligible.Count) {
        throw 'The existing All Chocolatey package requires a real earlier approved stable upgrade baseline.'
    }
    $selected = $eligible[0]
    if ($selected.HashAlgorithm -cne 'SHA512' -or $selected.DownloadUrl -cne "https://community.chocolatey.org/api/v2/package/grate/$($selected.Version)") {
        throw 'The public Chocolatey baseline has unexpected integrity metadata or download origin.'
    }
    try {
        $hash = [Convert]::FromBase64String($selected.PackageHash)
    } catch {
        throw 'The public Chocolatey baseline has an invalid package digest.'
    }
    if ($hash.Length -ne 64) {
        throw 'The public Chocolatey baseline must supply a full SHA512 digest.'
    }
    $selected
}

function Get-WindowsChannelChocolateyBaseline {
    param(
        [Parameter(Mandatory)][string]$Version,
        [scriptblock]$ReadFeed = { param(
                                       $uri
                                   ) (Invoke-WebRequest -Uri $uri -TimeoutSec 60).Content }
    )

    $uri = 'https://community.chocolatey.org/api/v2/FindPackagesById()?id=%27grate%27'
    $visited = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $entries = [Collections.Generic.List[object]]::new()
    while ($uri) {
        if ($visited.Count -ge 100 -or !$visited.Add($uri) -or !$uri.StartsWith('https://community.chocolatey.org/api/v2/', [StringComparison]::Ordinal)) {
            throw 'Chocolatey baseline pagination is excessive, cyclic or has an unexpected origin.'
        }
        [xml]$feed = & $ReadFeed $uri
        foreach ($entry in $feed.SelectNodes("//*[local-name()='entry']")) {
            $properties = $entry.SelectSingleNode(".//*[local-name()='properties']")
            $content = $entry.SelectSingleNode("./*[local-name()='content']")
            $title = $entry.SelectSingleNode("./*[local-name()='title']")
            $propertyId = $properties.SelectSingleNode("./*[local-name()='Id']")
            if (!$title -or $title.InnerText -cne 'grate' -or ($propertyId -and $propertyId.InnerText -cne $title.InnerText)) {
                throw 'Chocolatey baseline Atom entry does not identify the requested grate package.'
            }
            $entries.Add([pscustomobject]@{
                Id = $title.InnerText
                Version = $properties.SelectSingleNode("./*[local-name()='Version']").InnerText
                Approved = $properties.SelectSingleNode("./*[local-name()='IsApproved']").InnerText -ceq 'true'
                PackageHash = $properties.SelectSingleNode("./*[local-name()='PackageHash']").InnerText
                HashAlgorithm = $properties.SelectSingleNode("./*[local-name()='PackageHashAlgorithm']").InnerText
                DownloadUrl = [string]$content.src
            })
        }
        $next = @($feed.SelectNodes("/*[local-name()='feed']/*[local-name()='link' and @rel='next']"))
        if ($next.Count -gt 1) {
            throw 'Chocolatey baseline pagination returned multiple next-page links.'
        }
        $uri = if ($next.Count -eq 1) { [string]$next[0].href } else { $null }
    }
    Select-WindowsChannelChocolateyBaseline -Entries $entries.ToArray() -Version $Version
}

function Test-WindowsChannelChocolateyUpgrade {
    param(
        [Parameter(Mandatory)][string]$Version,
        [Parameter(Mandatory)][string]$CandidateDirectory,
        [Parameter(Mandatory)][string]$ExpectedExecutable,
        [Parameter(Mandatory)][string]$ExpectedSQLiteVersion,
        [Parameter(Mandatory)][string]$OutputDirectory
    )

    if ($ExpectedSQLiteVersion -cnotmatch '\A(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\z') {
        throw 'A source-resolved numeric SQLite version is required for upgrade verification.'
    }
    New-Item -ItemType Directory -Path "$OutputDirectory/baseline", "$OutputDirectory/sql/up", "$OutputDirectory/sql/afterMigration" -Force | Out-Null
    $baseline = Get-WindowsChannelChocolateyBaseline -Version $Version
    $baseline | ConvertTo-Json | Set-Content -LiteralPath "$OutputDirectory/baseline-selection.json" -Encoding utf8NoBOM
    $package = "$OutputDirectory/baseline/grate.$($baseline.Version).nupkg"
    Invoke-WebRequest -Uri $baseline.DownloadUrl -OutFile $package -TimeoutSec 120
    $hash = [Convert]::ToBase64String([Convert]::FromHexString((Get-FileHash -LiteralPath $package -Algorithm SHA512).Hash))
    if ($hash -cne $baseline.PackageHash) {
        throw 'Downloaded earlier Chocolatey package does not match the approved public feed bytes.'
    }
    $choco = (Get-Command choco.exe).Source
    $installed = Join-Path $env:ChocolateyInstall 'lib/grate/tools/grate.exe'
    $shim = Join-Path $env:ChocolateyInstall 'bin/grate.exe'
    Invoke-WindowsChannelCommand -FilePath $choco -Arguments @('install', 'grate', "--version=$($baseline.Version)", "--source=$OutputDirectory/baseline", '--yes', '--no-progress', '--limit-output') -Log "$OutputDirectory/baseline-install.log"
    $metadata = [Diagnostics.FileVersionInfo]::GetVersionInfo($installed)
    if ($metadata.ProductVersion.Split('+')[0] -cne $baseline.Version) {
        throw 'Earlier public Chocolatey installation did not deploy the selected baseline.'
    }
    Invoke-WindowsChannelCommand -FilePath $shim -Arguments @('--help') -Log "$OutputDirectory/baseline-shim-help.log"
    'CREATE TABLE channel_upgrade_data(value INTEGER CHECK(value=42)); INSERT INTO channel_upgrade_data VALUES(42);' |
        Set-Content -LiteralPath "$OutputDirectory/sql/up/001_existing.sql" -Encoding utf8NoBOM
    $assertions = "CREATE TEMP TABLE upgrade_assert(value INTEGER CHECK(value=1)); INSERT INTO upgrade_assert SELECT CASE WHEN COUNT(*)=1 AND MIN(value)=42 THEN 1 ELSE 0 END FROM channel_upgrade_data; INSERT INTO upgrade_assert SELECT COUNT(*) FROM grate_ScriptsRun WHERE script_name='001_existing.sql'; INSERT INTO upgrade_assert SELECT CASE WHEN COUNT(*)=0 THEN 1 ELSE 0 END FROM grate_ScriptsRunErrors;"
    $assertions | Set-Content -LiteralPath "$OutputDirectory/sql/afterMigration/001_assert.sql" -Encoding utf8NoBOM
    $arguments = @('--databasetype', 'sqlite', '--connectionstring', "Data Source=$OutputDirectory/existing.db", '--files', "$OutputDirectory/sql", '--output', "$OutputDirectory/migrations", '--silent')
    foreach ($attempt in 1..2) {
        Invoke-WindowsChannelCommand -FilePath $installed -Arguments $arguments -Log "$OutputDirectory/baseline-migration-$attempt.log"
    }
    $existingHash = (Get-FileHash -LiteralPath "$OutputDirectory/existing.db" -Algorithm SHA256).Hash
    Invoke-WindowsChannelCommand -FilePath $choco -Arguments @('upgrade', 'grate', "--version=$Version", "--source=$CandidateDirectory", '--yes', '--no-progress', '--limit-output') -Log "$OutputDirectory/upgrade.log"
    if ((Get-FileHash -LiteralPath "$OutputDirectory/existing.db" -Algorithm SHA256).Hash -cne $existingHash) {
        throw 'Chocolatey upgrade changed the existing migration database.'
    }
    $freshProbe = "$OutputDirectory/fresh-payload-probe"
    New-Item -ItemType Directory -Path $freshProbe -Force | Out-Null
    Test-WindowsChannelExecutable -Executable $installed -ExpectedExecutable $ExpectedExecutable -Distribution All -Version $Version -ExpectedSQLiteVersion $ExpectedSQLiteVersion -OutputDirectory $freshProbe
    Invoke-WindowsChannelCommand -FilePath $shim -Arguments @('--help') -Log "$OutputDirectory/upgraded-shim-help.log"
    ($assertions + " INSERT INTO upgrade_assert SELECT CASE WHEN sqlite_version()='$ExpectedSQLiteVersion' THEN 1 ELSE 0 END;") |
        Set-Content -LiteralPath "$OutputDirectory/sql/afterMigration/001_assert.sql" -Encoding utf8NoBOM
    foreach ($attempt in 1..2) {
        Invoke-WindowsChannelCommand -FilePath $installed -Arguments $arguments -Log "$OutputDirectory/upgraded-existing-migration-$attempt.log"
    }
    $upgradedHash = (Get-FileHash -LiteralPath "$OutputDirectory/existing.db" -Algorithm SHA256).Hash
    Invoke-WindowsChannelCommand -FilePath $choco -Arguments @('uninstall', 'grate', '--yes', '--no-progress', '--limit-output') -Log "$OutputDirectory/upgrade-uninstall.log"
    if ((Test-Path -LiteralPath $installed) -or (Test-Path -LiteralPath $shim) -or
        (Get-FileHash -LiteralPath "$OutputDirectory/existing.db" -Algorithm SHA256).Hash -cne $upgradedHash) {
        throw 'Upgraded Chocolatey uninstall left the command or changed the external migration database.'
    }
    [pscustomobject]@{
        Status = 'passed'
        BaselineVersion = $baseline.Version
        BaselinePackageSha512 = $baseline.PackageHash
        PreservedDatabaseBeforeUpgradeSha256 = $existingHash
        PreservedDatabaseBeforeUninstallSha256 = $upgradedHash
    }
}

function ConvertFrom-WindowsChannelCentralPackagesBase64 {
    param(
        [Parameter(Mandatory)][string]$Content
    )

    $bytes = [Convert]::FromBase64String($Content)
    $stream = [IO.MemoryStream]::new($bytes, $false)
    $reader = [IO.StreamReader]::new($stream, [Text.UTF8Encoding]::new($false, $true), $true)
    try {
        # StreamReader consumes an encoding preamble. Casting a UTF-8 string
        # containing U+FEFF directly to XML leaves a non-XML leading character.
        [xml]$document = $reader.ReadToEnd()
    } finally {
        $reader.Dispose()
        $stream.Dispose()
    }
    $document
}
