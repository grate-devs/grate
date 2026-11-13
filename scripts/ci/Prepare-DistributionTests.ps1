#!/usr/bin/env pwsh
param(
    [Parameter(Mandatory)]
    [string]$OutputDirectory,
    [string]$RuntimeIdentifier = 'linux-x64'
)

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true
. "$PSScriptRoot/Distribution.Common.ps1"
. "$PSScriptRoot/Distribution.Build.ps1"
. "$PSScriptRoot/Distribution.Artifacts.ps1"

$repository = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$output = [IO.Path]::GetFullPath($OutputDirectory)
if (Test-Path -LiteralPath $output) {
    throw 'Use a fresh output directory to prepare distribution artifacts.'
}

Push-Location $repository
try {
    $frameworks = @(Get-DistributionFrameworks)
    $framework = $frameworks[-1]
    $version = '0.0.0-ci.' + [Guid]::NewGuid().ToString('N')
    foreach ($distribution in @('All', 'SQLite', 'SQLServer', 'MariaDB', 'PostgreSQL', 'Oracle')) {
        $stage = "$output/build/$distribution"
        $packageId = if ($distribution -eq 'All') { 'grate' } else { 'grate-' + $distribution.ToLowerInvariant() }
        Publish-DistributionCli -Distribution $distribution -Framework $framework `
            -RuntimeIdentifier $RuntimeIdentifier -Version $version -OutputDirectory $stage
        Build-DistributionTool -Distribution $distribution -Frameworks $frameworks `
            -Version $version -PackageId $packageId -OutputDirectory $stage

        # Publish only final payloads, never the large build/intermediate trees.
        $destination = "$output/profiles/$distribution"
        Copy-DistributionPayload -Source "$stage/standalone" -Destination "$destination/standalone"
        Copy-DistributionPayload -Source "$stage/packages" -Destination "$destination/packages"
        Copy-Item -LiteralPath "$stage/grate.deps.json" -Destination "$destination/grate.deps.json"
        $identity = Get-DistributionPayloadIdentity -Kind 'Distribution' -RuntimeIdentifier $RuntimeIdentifier -Frameworks $frameworks
        $identity.Distribution = $distribution
        $identity.PackageId = $packageId
        $identity.Version = $version
        Write-DistributionPayloadManifest -Directory $destination -Identity $identity
    }
    foreach ($database in @('Sqlite', 'SqlServer', 'SqlServerCaseSensitive', 'PostgreSQL', 'MariaDB', 'Oracle')) {
        # Share normal All build outputs; no selected-profile property reaches the tests.
        $stage = "$output/build/tests"
        Build-DistributionTests -Database $database -Framework $framework -OutputDirectory $stage
        $source = "$stage/test-build/bin/CommandLine.$database/release_$framework"
        $destination = "$output/tests/$database"
        Copy-DistributionPayload -Source $source -Destination "$destination/payload"
        $identity = Get-DistributionPayloadIdentity -Kind 'Tests' -RuntimeIdentifier $RuntimeIdentifier -Frameworks $frameworks
        $identity.Database = $database
        $identity.Distribution = 'All'
        Write-DistributionPayloadManifest -Directory $destination -Identity $identity
    }
    Write-Host 'PASS: prepared six standalone/tool profiles and six complete JIT test payloads.'
} finally {
    Pop-Location
}
