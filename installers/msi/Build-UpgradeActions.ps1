#!/usr/bin/env pwsh
param (
    [Parameter(Mandatory=$true)] [ValidateSet('x64', 'arm64')] [string]$Architecture,
    [Parameter(Mandatory=$true)] [string]$OutputDirectory
)
$ErrorActionPreference = 'Stop'
if (!$IsWindows) { throw 'Building the native MSI upgrade action requires Visual Studio C++ tools and Windows SDK on Windows.' }
New-Item -ItemType Directory -Force -Path $OutputDirectory | Out-Null
$OutputDirectory = (Resolve-Path -LiteralPath $OutputDirectory).Path
$contract = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'identity-contract.json') -Raw | ConvertFrom-Json
@"
#define GRATE_LEGACY_PRODUCT_CODE L"$($contract.LegacyProductCode)"
#define GRATE_X64_UPGRADE_CODE L"$($contract.Architectures.x64.UpgradeCode)"
#define GRATE_ARM64_UPGRADE_CODE L"$($contract.Architectures.arm64.UpgradeCode)"
#define GRATE_CURRENT_UPGRADE_CODE L"$($contract.Architectures.$Architecture.UpgradeCode)"
"@ | Set-Content -LiteralPath (Join-Path $OutputDirectory 'IdentityContract.h')
$vswhere = Join-Path ([Environment]::GetFolderPath('ProgramFilesX86')) 'Microsoft Visual Studio/Installer/vswhere.exe'
if (!(Test-Path -LiteralPath $vswhere)) { throw 'MSI upgrade actions require Visual Studio C++ build tools (vswhere.exe not found).' }
$visualStudio = & $vswhere -latest -products '*' -property installationPath
if ($LASTEXITCODE -ne 0 -or !$visualStudio) { throw 'Cannot locate Visual Studio for the native MSI upgrade action.' }
$vcvars = Join-Path $visualStudio 'VC/Auxiliary/Build/vcvarsall.bat'
if (!(Test-Path -LiteralPath $vcvars)) { throw 'Visual Studio C++ tools are required to build the MSI upgrade action.' }
$hostArchitecture = [Runtime.InteropServices.RuntimeInformation]::ProcessArchitecture.ToString().ToLowerInvariant()
$toolArchitecture = switch ($hostArchitecture) {
    'arm64' { if ($Architecture -eq 'arm64') { 'arm64' } else { 'arm64_amd64' } }
    'x64' { if ($Architecture -eq 'x64') { 'amd64' } else { 'amd64_arm64' } }
    default { if ($Architecture -eq 'x64') { 'x86_amd64' } else { 'x86_arm64' } }
}
$source = Join-Path $PSScriptRoot 'LegacyUpgradeActions.cpp'
$dll = Join-Path $OutputDirectory 'GrateUpgradeActions.dll'
$machine = $Architecture.ToUpperInvariant()
$batch = Join-Path $OutputDirectory 'build-upgrade-actions.cmd'
@"
@echo off
call "$vcvars" $toolArchitecture
if errorlevel 1 exit /b %errorlevel%
cl.exe /nologo /std:c++17 /EHsc /LD /MT /O2 /W4 /WX /DUNICODE /D_UNICODE /D_WIN32_MSI=500 /D_WIN32_WINNT=0x0A00 /I"$OutputDirectory" /Fo"$OutputDirectory\LegacyUpgradeActions.obj" /Fe"$dll" "$source" /link /NOLOGO /MACHINE:$machine /IMPLIB:"$OutputDirectory\GrateUpgradeActions.lib" msi.lib advapi32.lib
exit /b %errorlevel%
"@ | Set-Content -LiteralPath $batch
& $env:ComSpec /d /c $batch
if ($LASTEXITCODE -ne 0 -or !(Test-Path -LiteralPath $dll)) { throw "Native MSI upgrade action build failed with exit code $LASTEXITCODE." }
$dll
