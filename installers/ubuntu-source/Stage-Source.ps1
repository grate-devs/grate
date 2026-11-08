#!/usr/bin/env pwsh
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$OutputDirectory,

    [ValidatePattern('^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$')]
    [string]$Version = '0.0.1',

    [switch]$UseUbuntuArchiveAnalyzer
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true

$repository = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '../..')).Path
$output = [IO.Path]::GetFullPath($OutputDirectory)
$repositoryPrefix = $repository + [IO.Path]::DirectorySeparatorChar
if ($output -eq $repository -or $output.StartsWith($repositoryPrefix, [StringComparison]::Ordinal)) {
    throw 'Stage outside the checkout so no source, developer cache or existing build output can become an input.'
}
if (Test-Path -LiteralPath $output) {
    throw 'OutputDirectory must not exist. Choose a new directory; this script never deletes existing work.'
}

$sourceVersion = $Version
$sourceName = "grate-mariadb-$sourceVersion"
$revision = (& git -C $repository rev-parse HEAD).Trim()
$trackedPaths = @(& git -C $repository ls-tree -r --name-only HEAD)
$binaryInputs = @($trackedPaths | Where-Object { $_ -match '(^|/)(bin|obj|\.nuget)/|\.(nupkg|deb|dll|exe|so|dylib)$' })
if ($binaryInputs.Count -gt 0) {
    throw "The selected revision contains binary/build inputs; review them before staging: $($binaryInputs -join ', ')"
}

# The archive is the committed source, not a recursive copy of the working tree.
# Refuse tracked product changes instead of silently building stale code.
$productChanges = @(& git -C $repository diff HEAD --name-only -- src 'Directory.Build.*' 'Directory.Packages.*' '*uGet.*' CodeAnalysis.ruleset global.json docs/skills)
if ($productChanges.Count -gt 0) {
    throw "Commit product changes before staging: $($productChanges -join ', ')"
}

New-Item -ItemType Directory -Path $output | Out-Null
$originalTarball = Join-Path $output "grate-mariadb_${sourceVersion}.orig.tar.gz"
& git -C $repository archive --format=tar.gz "--prefix=$sourceName/" "--output=$originalTarball" $revision
& tar -xzf $originalTarball -C $output
$sourceDirectory = Join-Path $output $sourceName
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'debian') -Destination $sourceDirectory -Recurse
$revision | Set-Content -LiteralPath (Join-Path $sourceDirectory 'debian/source-revision') -Encoding utf8
$Version | Set-Content -LiteralPath (Join-Path $sourceDirectory 'debian/grate-version') -Encoding utf8
$changelog = Join-Path $sourceDirectory 'debian/changelog'
$changelogText = Get-Content -LiteralPath $changelog -Raw
$changelogText.Replace('grate-mariadb (0.0.1-1~poc1)', "grate-mariadb ($Version-1~poc1)") | Set-Content -LiteralPath $changelog -Encoding utf8 -NoNewline
$patches = Join-Path $sourceDirectory 'debian/patches'
if ($UseUbuntuArchiveAnalyzer) {
    'use-ubuntu-archive-analyzers.patch' | Set-Content -LiteralPath (Join-Path $patches 'series') -Encoding utf8
}
elseif (Test-Path -LiteralPath $patches) {
    Remove-Item -LiteralPath $patches -Recurse -Force
}
$notices = Join-Path $PSScriptRoot 'notices'
if (Test-Path -LiteralPath $notices) {
    Copy-Item -LiteralPath $notices -Destination (Join-Path $sourceDirectory 'debian/notices') -Recurse
}

$origin = [ordered]@{
    sourceRevision = $revision
    sourceTarball = [IO.Path]::GetFileName($originalTarball)
    sourceTarballSha256 = (Get-FileHash -LiteralPath $originalTarball -Algorithm SHA256).Hash.ToLowerInvariant()
    profile = 'MariaDB'
    targetFramework = 'net10.0'
    version = $Version
    ubuntuArchiveAnalyzer = [bool]$UseUbuntuArchiveAnalyzer
    sourceDirectory = $sourceName
    recipe = 'Local working-tree installers/ubuntu-source/debian; inspect alongside source revision.'
}
$origin | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $output 'source-origin.json') -Encoding utf8
Write-Output $sourceDirectory
