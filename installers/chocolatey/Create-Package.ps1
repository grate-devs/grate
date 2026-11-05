#!/usr/bin/env pwsh

param (
    [Parameter(Mandatory=$true)] [string]$grateExe,
    [Parameter(Mandatory=$true)] [string]$version
)

$ErrorActionPreference = 'Stop'
$grateExe = (Resolve-Path -LiteralPath $grateExe).Path
$toolsDir = Join-Path $PSScriptRoot 'grate/tools'
Copy-Item -LiteralPath $grateExe -Destination (Join-Path $toolsDir 'grate.exe') -Force

$hash = (Get-FileHash -LiteralPath $grateExe -Algorithm SHA256).Hash
$releaseUrl = "https://github.com/grate-devs/grate/releases/download/$version"
$archive = "grate-win-x64-self-contained-$version.zip"
@"
VERIFICATION
This package embeds the self-contained Windows x64 executable from the grate $version release.

1. Download the upstream archive and checksum list:
   $releaseUrl/$archive
   $releaseUrl/checksums.sha256
2. Run Get-FileHash -Algorithm SHA256 .\$archive and compare the result with the archive's entry in checksums.sha256.
3. Extract the archive and this .nupkg (a ZIP archive) to separate directories.
4. Run Get-FileHash -Algorithm SHA256 on grate.exe from the release archive and tools\grate.exe from the package.
   Both must match this SHA256: $hash
"@ | Set-Content -LiteralPath (Join-Path $toolsDir 'VERIFICATION.txt')

& choco pack --version=$version (Join-Path $PSScriptRoot 'grate/grate.nuspec') --outputdirectory=$PSScriptRoot
if ($LASTEXITCODE -ne 0) { throw "choco pack failed with exit code $LASTEXITCODE." }
