#!/usr/bin/env pwsh
param(
    [Parameter(Mandatory)]
    [ValidatePattern('\A[0-9]+\.[0-9]+\.[0-9]+\z')]
    [string]$version,
    [Parameter(Mandatory)]
    [string]$artifactDirectory,
    [string]$releaseTag = $version,
    [string]$outputPath,
    [string]$OutputDirectory = (Join-Path $PSScriptRoot '../../artifacts/homebrew/cask'),
    [ValidateSet('All', 'SQLite', 'SQLServer', 'MariaDB', 'PostgreSQL', 'Oracle')]
    [string]$Distribution = 'All',
    [switch]$AllDistributions
)

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot/Homebrew.Common.ps1"
if ($releaseTag -cne $version -and $releaseTag -cne "v$version") {
    throw 'releaseTag must be the version or the version prefixed with v.'
}
if ($AllDistributions -and ($outputPath -or $Distribution -ne 'All')) {
    throw 'Use OutputDirectory and the default Distribution with AllDistributions.'
}
$profiles = if ($AllDistributions) {
    @('All', 'SQLite', 'SQLServer', 'MariaDB', 'PostgreSQL', 'Oracle')
} else {
    @($Distribution)
}
# Resolve and hash every final input before replacing any manifest.
$candidates = @(foreach ($name in $profiles) {
    $profile = Get-HomebrewDistribution -Distribution $name
    $armArchive = Join-Path $artifactDirectory "$($profile.PackageId)-osx-arm64-self-contained-$version.zip"
    $intelArchive = Join-Path $artifactDirectory "$($profile.PackageId)-osx-x64-self-contained-$version.zip"
    @{
        Version = $version
        ReleaseTag = $releaseTag
        Distribution = $name
        Arm64Sha256 = (Get-FileHash -LiteralPath $armArchive -Algorithm SHA256).Hash
        X64Sha256 = (Get-FileHash -LiteralPath $intelArchive -Algorithm SHA256).Hash
        Output = if ($outputPath) { $outputPath } else { Join-Path $OutputDirectory "$($profile.PackageId).rb" }
    }
})
foreach ($candidate in $candidates) {
    Write-HomebrewCask @candidate
}
