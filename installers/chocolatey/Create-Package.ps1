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
@"
VERIFICATION
This package embeds the self-contained Windows x64 grate executable from:
https://github.com/grate-devs/grate/releases
Release artifact: grate-win-x64-self-contained-$version.zip
SHA256 of tools/grate.exe: $hash
"@ | Set-Content -LiteralPath (Join-Path $toolsDir 'VERIFICATION.txt')

& choco pack --version=$version (Join-Path $PSScriptRoot 'grate/grate.nuspec') --outputdirectory=$PSScriptRoot
if ($LASTEXITCODE -ne 0) { throw "choco pack failed with exit code $LASTEXITCODE." }
