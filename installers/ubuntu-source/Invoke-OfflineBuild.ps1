#!/usr/bin/env pwsh
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$StagedDirectory,

    [Parameter(Mandatory)]
    [string]$EvidenceDirectory,

    [string]$BuilderImage = 'grate-ubuntu-source:26.04',

    [ValidateSet('arm64', 'amd64')]
    [string]$Architecture = 'arm64',

    [switch]$FrameworkDependentRestoreOnly,

    [string]$DapperPackage,

    [string]$MySqlConnectorPackage
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true

$stage = (Resolve-Path -LiteralPath $StagedDirectory).Path
if (!(Test-Path -LiteralPath (Join-Path $stage 'source-origin.json'))) {
    throw 'StagedDirectory must be the output directory created by Stage-Source.ps1.'
}
$origin = Get-Content -LiteralPath (Join-Path $stage 'source-origin.json') -Raw | ConvertFrom-Json
if ($origin.sourceDirectory -notmatch '^grate-mariadb-[0-9]+\.[0-9]+\.[0-9]+$') {
    throw 'Invalid staged source directory identity.'
}
$source = Join-Path $stage $origin.sourceDirectory
if (!(Test-Path -LiteralPath (Join-Path $source 'debian/rules'))) {
    throw 'Staged source and debian/rules are missing.'
}
$contamination = @(Get-ChildItem -LiteralPath $source -Recurse -Directory -Force | Where-Object { $_.Name -in @('bin', 'obj', '.nuget-packages', '.build', '.dotnet-home') })
if ($contamination.Count -gt 0) {
    throw 'The source staging directory contains prior build/cache state. Stage into a fresh directory before each attempt.'
}
$evidence = [IO.Path]::GetFullPath($EvidenceDirectory)
if (Test-Path -LiteralPath $evidence) {
    throw 'EvidenceDirectory must not exist. Previous evidence must remain intact.'
}
New-Item -ItemType Directory -Path $evidence | Out-Null
Copy-Item -LiteralPath (Join-Path $stage 'source-origin.json') -Destination $evidence
if ([bool]$DapperPackage -ne [bool]$MySqlConnectorPackage) {
    throw 'Supply both source-built dependency packages together.'
}
$sourceBuiltInputs = @()
if ($DapperPackage) {
    $localFeed = Join-Path $stage 'source-built-feed'
    New-Item -ItemType Directory -Path $localFeed | Out-Null
    $identities = @(
        @{ Id = 'Dapper'; Version = '2.1.89'; Commit = 'eb47546a408bbf6c178bda4f04dc205bc51ffbfe'; Path = $DapperPackage }
        @{ Id = 'MySqlConnector'; Version = '2.6.2'; Commit = '775689bb3e1ab55d16171e0795264fa746e364c4'; Path = $MySqlConnectorPackage }
    )
    foreach ($identity in $identities) {
        $package = (Resolve-Path -LiteralPath $identity.Path).Path
        $archive = [IO.Compression.ZipFile]::OpenRead($package)
        try {
            $entry = $archive.GetEntry("$($identity.Id).nuspec")
            if ($null -eq $entry) {
                throw "Missing $($identity.Id) package metadata."
            }
            $reader = [IO.StreamReader]::new($entry.Open())
            try {
                [xml]$metadata = $reader.ReadToEnd()
            }
            finally {
                $reader.Dispose()
            }
            if ($metadata.package.metadata.id -cne $identity.Id -or $metadata.package.metadata.version -cne $identity.Version -or $metadata.package.metadata.repository.commit -cne $identity.Commit) {
                throw "Unexpected source-built package identity/revision for $($identity.Id)."
            }
        }
        finally {
            $archive.Dispose()
        }
        $fileName = "$($identity.Id).$($identity.Version).nupkg"
        Copy-Item -LiteralPath $package -Destination (Join-Path $localFeed $fileName)
        $sourceBuiltInputs += [ordered]@{
            id = $identity.Id
            version = $identity.Version
            sourceCommit = $identity.Commit
            fileName = $fileName
            sha256 = (Get-FileHash -LiteralPath $package -Algorithm SHA256).Hash.ToLowerInvariant()
        }
    }
    $sourceBuiltInputs | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $source 'debian/source-built-inputs.json') -Encoding utf8
    Copy-Item -LiteralPath (Join-Path $source 'debian/source-built-inputs.json') -Destination $evidence
}

# Resolve locally; --pull=never below prevents implicit provisioning during build.
$inspection = & docker image inspect --platform "linux/$Architecture" $BuilderImage
$inspection | Set-Content -LiteralPath (Join-Path $evidence 'builder-image.json') -Encoding utf8
$buildCommand = @'
set -eu
printf '%s\n' '=== Distribution and architecture ==='
cat /etc/os-release
dpkg --print-architecture
printf '%s\n' '=== Installed build inputs ==='
dpkg-query -W -f='${binary:Package}\t${Version}\n'
printf '%s\n' '=== Distribution SDK ==='
cd /
dotnet --info
cd /work/grate-mariadb-0.0.1
printf '%s\n' '=== Construct source package ==='
dpkg-buildpackage -S -us -uc
'@
if ($FrameworkDependentRestoreOnly) {
    $buildCommand += @'

printf '%s\n' '=== Offline framework-dependent restore only ==='
make -f debian/rules override_dh_auto_configure
export DOTNET_CLI_HOME=/tmp/grate-dotnet-home
export NUGET_HTTP_CACHE_PATH=/tmp/grate-nuget-http
export NUGET_PLUGINS_CACHE_PATH=/tmp/grate-nuget-plugins
export DOTNET_CLI_TELEMETRY_OPTOUT=1
export DOTNET_SKIP_FIRST_TIME_EXPERIENCE=1
cd /
dotnet restore /work/grate-mariadb-0.0.1/src/grate/grate.csproj -p:TargetFrameworks=net10.0 -p:GrateDistribution=MariaDB -p:SelfContained=false -p:PublishTrimmed=false -p:PublishSingleFile=false -p:UseAppHost=false -p:NuGetAudit=false --configfile /work/grate-mariadb-0.0.1/debian/.build/NuGet.Config --packages /work/grate-mariadb-0.0.1/debian/.nuget-packages
'@
    $operation = 'framework-dependent restore'
}
else {
    $buildCommand += @'

printf '%s\n' '=== Offline binary build ==='
dpkg-buildpackage -b -us -uc
'@
    $operation = 'self-contained package build'
}
$buildCommand = $buildCommand.Replace('/work/grate-mariadb-0.0.1', "/work/$($origin.sourceDirectory)")
$arguments = @(
    'run', '--rm', '--pull=never', '--network=none',
    '--tmpfs', '/tmp:rw,exec,nosuid,size=512m',
    '--platform', "linux/$Architecture",
    '--mount', "type=bind,src=$stage,dst=/work"
)
if ($DapperPackage) {
    $arguments += @('--mount', "type=bind,src=$localFeed,dst=/work/source-built-feed,readonly", '--env', 'GRATE_SOURCE_BUILT_FEED=/work/source-built-feed')
}
$arguments += @($BuilderImage, 'sh', '-c', $buildCommand)
$arguments | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $evidence 'docker-arguments.json') -Encoding utf8

# Keep the failing restore log and propagate the nonzero result. It is evidence
# of the blocker, not a successful package build.
$previousNativePreference = $PSNativeCommandUseErrorActionPreference
try {
    $PSNativeCommandUseErrorActionPreference = $false
    & docker @arguments 2>&1 | Tee-Object -FilePath (Join-Path $evidence 'build.log') | Out-Host
    $buildExitCode = $LASTEXITCODE
}
finally {
    $PSNativeCommandUseErrorActionPreference = $previousNativePreference
}
if ($buildExitCode -eq 0) {
    foreach ($inputPackage in $sourceBuiltInputs) {
        $id = $inputPackage.id.ToLowerInvariant()
        $cachedPackage = Join-Path $source "debian/.nuget-packages/$id/$($inputPackage.version)/$id.$($inputPackage.version).nupkg"
        if (!(Test-Path -LiteralPath $cachedPackage) -or (Get-FileHash -LiteralPath $cachedPackage -Algorithm SHA256).Hash.ToLowerInvariant() -cne $inputPackage.sha256) {
            throw "The build did not restore the supplied $($inputPackage.id) package bytes."
        }
    }
}
[ordered]@{
    operation = $operation
    exitCode = $buildExitCode
    sourceBuiltInputs = $sourceBuiltInputs
    sourceBuiltPackageBytesVerified = $buildExitCode -eq 0 -and $sourceBuiltInputs.Count -gt 0
    sourcePackageProduced = @(Get-ChildItem -LiteralPath $stage -Filter '*.dsc').Count -gt 0
    binaryPackageProduced = @(Get-ChildItem -LiteralPath $stage -Filter '*.deb').Count -gt 0
    binaryPackages = @(
        foreach ($binaryPackage in @(Get-ChildItem -LiteralPath $stage -Filter '*.deb')) {
            [ordered]@{
                path = $binaryPackage.FullName
                sha256 = (Get-FileHash -LiteralPath $binaryPackage.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
            }
        }
    )
} | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $evidence 'result.json') -Encoding utf8
if ($buildExitCode -ne 0) {
    throw "Offline $operation failed (exit $buildExitCode). See $evidence/build.log. The preferred self-contained package remains unachieved."
}
