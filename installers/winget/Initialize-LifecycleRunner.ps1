#!/usr/bin/env pwsh
param([Parameter(Mandatory)][string]$OutputDirectory)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
if (!$IsWindows -or $env:GITHUB_ACTIONS -ne 'true' -or $env:RUNNER_ENVIRONMENT -ne 'github-hosted') {
    throw 'WinGet lifecycle setup requires a disposable GitHub-hosted Windows runner.'
}
$arch = [Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString().ToLowerInvariant()
New-Item -ItemType Directory -Force $OutputDirectory | Out-Null
$downloads = @(
    @{ Name = 'DesktopAppInstaller_Dependencies.zip'; Hash = 'BA875AFE9D190F61218985AC0292A99D1DB710BF93E13C68944CA9D89F0D82D1' },
    @{ Name = 'Microsoft.DesktopAppInstaller_8wekyb3d8bbwe.msixbundle'; Hash = '65DEA9C01CE08EE7B763366B27C0E651F97DB857C11CA9B9C301826C10092F2E' }
)
foreach ($item in $downloads) {
    $path = Join-Path $OutputDirectory $item.Name
    Invoke-WebRequest "https://github.com/microsoft/winget-cli/releases/download/v1.29.380/$($item.Name)" -OutFile $path
    if ((Get-FileHash $path -Algorithm SHA256).Hash -cne $item.Hash) { throw "Pinned WinGet checksum mismatch: $($item.Name)" }
}
Expand-Archive "$OutputDirectory/DesktopAppInstaller_Dependencies.zip" "$OutputDirectory/dependencies" -Force
# Appx's Windows PowerShell module also works from pwsh via compatibility import.
Import-Module Appx -UseWindowsPowerShell
# Install dependencies individually: the Windows PowerShell compatibility proxy
# otherwise serializes the DependencyPath array as one newline-separated path.
foreach ($pattern in @('*VCLibs.140.00_*', '*UWPDesktop*', '*WindowsAppRuntime*')) {
    foreach ($dependency in @(Get-ChildItem "$OutputDirectory/dependencies/$arch" -Filter $pattern)) {
        Add-AppxPackage -Path $dependency.FullName -ForceUpdateFromAnyVersion
    }
}
Add-AppxPackage -Path "$OutputDirectory/Microsoft.DesktopAppInstaller_8wekyb3d8bbwe.msixbundle" -ForceUpdateFromAnyVersion
$package = Get-AppxPackage -Name Microsoft.DesktopAppInstaller
$winget = Join-Path $package.InstallLocation 'winget.exe'
$actual = & $winget --version
if ($LASTEXITCODE -ne 0 -or $actual.Trim() -cne 'v1.29.380') { throw "Unexpected WinGet CLI version: $actual" }
Write-Host "Pinned WinGet $actual installed on disposable $arch runner."
$winget
