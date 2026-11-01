#!/usr/bin/env pwsh

param (
    [string]$grateExe, # Kept for the common Create-Installer.ps1 interface.
    [Parameter(Mandatory=$true)] [string]$version,
    [string]$releaseTag = $version,
    [string]$wingetCreate = 'wingetcreate'
)

$ErrorActionPreference = 'Stop'

# Match the current community manifest's three portable ZIPs and two MSIs.
# Run after release assets are published: wingetcreate downloads the real files
# and calculates their checksums. Generate locally; submission is separate.
$releaseUrl = "https://github.com/grate-devs/grate/releases/download/$releaseTag"
$urls = @(
    "$releaseUrl/grate-win-x86-self-contained-$version.zip|x86",
    "$releaseUrl/grate-win-x64-self-contained-$version.zip|x64",
    "$releaseUrl/grate-win-arm64-self-contained-$version.zip|arm64",
    "$releaseUrl/grate-msi-win-x64-$version.msi|x64",
    "$releaseUrl/grate-msi-win-arm64-$version.msi|arm64"
)
& $wingetCreate update erikbra.grate -u $urls -v $version -o (Join-Path $PSScriptRoot 'grate')
if ($LASTEXITCODE -ne 0) { throw "wingetcreate failed with exit code $LASTEXITCODE." }
