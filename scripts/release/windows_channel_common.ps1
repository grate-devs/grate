$ErrorActionPreference = 'Stop'
. "$PSScriptRoot/release_common.ps1"
. "$PSScriptRoot/distribution_profiles.ps1"

function Assert-WindowsChannelReleaseContext {
    param($Run, $Release, [string]$TagCommit, [string]$Version)

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
    param([string]$Version, [string]$ReleaseRunId)

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
    [pscustomobject]@{
        Version = $Version
        RunId = $ReleaseRunId
        SourceCommit = $tag.object.sha
        Release = $release
    }
}

function Save-WindowsChannelReleaseAsset {
    param($Context, [string]$Name, [string]$Directory)

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
    param([string]$FilePath, [string[]]$Arguments, [string]$Log, [int]$TimeoutSeconds = 600)

    $result = Invoke-ReleaseProcess -FilePath $FilePath -Arguments $Arguments -TimeoutSeconds $TimeoutSeconds
    ($result.Text + $result.ErrorText) | Set-Content -LiteralPath $Log -Encoding utf8NoBOM
    if ($result.ExitCode -ne 0) {
        throw "Channel verification command failed with exit $($result.ExitCode); see $Log."
    }
}

function Test-WindowsChannelExecutable {
    param([string]$Executable, [string]$ExpectedExecutable, [string]$Distribution, [string]$Version, [string]$OutputDirectory)

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
        New-Item -ItemType Directory -Path "$OutputDirectory/sql/up", "$OutputDirectory/sql/afterMigration" -Force | Out-Null
        'CREATE TABLE channel_probe(native_version TEXT CHECK(native_version = ''3.53.4'')); INSERT INTO channel_probe SELECT sqlite_version();' |
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
        [string]$ValidationRunId
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
