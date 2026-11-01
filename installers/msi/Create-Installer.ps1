#!/usr/bin/env pwsh

param (
    [Parameter(Mandatory=$true)] [string]$grateExe,
    [Parameter(Mandatory=$true)] [string]$version,
    [ValidateSet('x64', 'arm64')] [string]$arch = 'x64',
    [string]$upgradeCode = [Guid]::NewGuid()
)

$ErrorActionPreference = 'Stop'
& (Join-Path $PSScriptRoot 'Test-InstallerAuthoring.ps1')
$grateExe = (Resolve-Path -LiteralPath $grateExe).Path

function Recreate {
    param ([string]$dirName)
    $dir = Join-Path $PSScriptRoot $dirName
    if (Test-Path -LiteralPath $dir) {
        Remove-Item -LiteralPath $dir -Recurse -Force
    }
    return (New-Item -Path $dir -ItemType Directory).FullName
}

$wixDir = Recreate 'wix'
$tmpDir = Recreate 'tmp'

# WiX 3.14 supports ARM64 MSI packages; 3.11's candle only supports ARM32.
$wixZip = 'https://github.com/wixtoolset/wix3/releases/download/wix3141rtm/wix314-binaries.zip'
$localZip = Join-Path $tmpDir 'wix314-binaries.zip'
Invoke-WebRequest -Uri $wixZip -OutFile $localZip
$expectedHash = '6ac824e1642d6f7277d0ed7ea09411a508f6116ba6fae0aa5f2c7daa2ff43d31'
if ((Get-FileHash -LiteralPath $localZip -Algorithm SHA256).Hash -ne $expectedHash) {
    throw 'WiX archive checksum does not match the pinned release.'
}
Expand-Archive -LiteralPath $localZip -DestinationPath $wixDir

$wxs = Join-Path $tmpDir "grate-$version.wxs"
$wixobj = Join-Path $tmpDir "grate-$version.wixobj"
$msi = Join-Path $tmpDir "grate-$version.msi"
$template = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'grate.wxs') -Raw
$template.Replace('%%%VERSION%%%', $version).
    Replace('%%%UPGRADECODE%%%', $upgradeCode).
    Replace('%%%GRATEEXE%%%', [System.Security.SecurityElement]::Escape($grateExe)) |
    Set-Content -LiteralPath $wxs

& (Join-Path $wixDir 'candle.exe') -nologo -arch $arch $wxs -o $wixobj
if ($LASTEXITCODE -ne 0) { throw "WiX candle failed with exit code $LASTEXITCODE." }
# ICE91 is advisory for this per-user-only package: files intentionally live in
# LocalAppDataFolder. Keep it visible, without promoting LGHT1076 to an error.
# Test-InstallerAuthoring guards that exception's scope before building.
# https://learn.microsoft.com/windows/win32/msi/ice91
& (Join-Path $wixDir 'light.exe') -nologo -wx0204 $wixobj -o $msi
if ($LASTEXITCODE -ne 0) { throw "WiX light failed with exit code $LASTEXITCODE." }
if (-not (Test-Path -LiteralPath $msi)) { throw "MSI was not created: $msi" }
