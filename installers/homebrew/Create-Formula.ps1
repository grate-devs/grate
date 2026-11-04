#!/usr/bin/env pwsh

param (
    [Parameter(Mandatory=$true)]
    [ValidatePattern('\A[0-9]+\.[0-9]+\.[0-9]+\z')]
    [string]$version,
    [Parameter(Mandatory=$true)] [string]$sourceArchive,
    [string]$releaseTag = $version,
    [string]$outputPath = (Join-Path $PSScriptRoot '../../artifacts/homebrew/formula/grate.rb')
)

$ErrorActionPreference = 'Stop'

# Both supported tag forms let Homebrew infer the numeric formula version.
# Restrict them here rather than interpolating arbitrary text into Ruby.
if ($releaseTag -cne $version -and $releaseTag -cne "v$version") {
    throw 'releaseTag must be the version or the version prefixed with v.'
}
if (!(Test-Path -LiteralPath $sourceArchive -PathType Leaf)) {
    throw "Source archive does not exist: $sourceArchive"
}
if (![string]::Equals([IO.Path]::GetExtension($sourceArchive), '.gz', [StringComparison]::OrdinalIgnoreCase) -or
    ![string]::Equals([IO.Path]::GetExtension([IO.Path]::GetFileNameWithoutExtension($sourceArchive)), '.tar', [StringComparison]::OrdinalIgnoreCase)) {
    throw 'sourceArchive must be the downloaded source .tar.gz archive.'
}

# Hash the final downloaded source archive, not a locally repacked checkout.
$sourceHash = (Get-FileHash -LiteralPath $sourceArchive -Algorithm SHA256).Hash.ToLowerInvariant()
$template = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'grate.rb.in') -Raw
$formula = $template.Replace('@RELEASE_TAG@', $releaseTag).Replace('@SOURCE_SHA256@', $sourceHash)
if ($formula -match '@[A-Z_]+@') {
    throw 'The formula template contains unresolved placeholders.'
}

$outputPath = [IO.Path]::GetFullPath($outputPath)
$null = New-Item -ItemType Directory -Path ([IO.Path]::GetDirectoryName($outputPath)) -Force
[IO.File]::WriteAllText($outputPath, $formula, [Text.UTF8Encoding]::new($false))
Write-Host "Generated source-built formula: $outputPath"
