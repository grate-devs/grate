#!/usr/bin/env pwsh
param (
    [Parameter(Mandatory)] [string]$OutputDirectory
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
if (!$IsWindows) { throw 'Real WinGet preparation and MSI inspection require Windows. No installation is performed.' }
$OutputDirectory = [IO.Path]::GetFullPath($OutputDirectory)
New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null

# Fixed input provides reproducible preparation evidence, independently of what
# happens to be the latest release. This is not a release/publishing workflow.
$version = '2.1.6'
$tool = Join-Path $OutputDirectory 'wingetcreate.exe'
Invoke-WebRequest 'https://github.com/microsoft/winget-create/releases/download/v1.12.13.0/wingetcreate.exe' -OutFile $tool
if ((Get-FileHash $tool -Algorithm SHA256).Hash -ne '24042BD37915805615E6CF969AC57C6439124C3FE85823327F5F3FB24BD9FFEA') {
    throw 'wingetcreate checksum does not match the pinned release.'
}
$helper = Join-Path $PSScriptRoot 'Create-Installer.ps1'
& $helper -version $version -wingetCreate $tool -outputDirectory "$OutputDirectory/accepted-identity" *>&1 |
    Tee-Object -FilePath "$OutputDirectory/update.log"
& $helper -version $version -wingetCreate $tool -outputDirectory "$OutputDirectory/migration-candidate" -PrepareMigration *>&1 |
    Tee-Object -FilePath "$OutputDirectory/migration.log"

$msiDirectory = Join-Path (Split-Path $PSScriptRoot) 'msi'
$release = Invoke-RestMethod "https://api.github.com/repos/grate-devs/grate/releases/tags/$version"
foreach ($arch in @('x64', 'arm64')) {
    $asset = @($release.assets | Where-Object name -CEQ "grate-msi-win-$arch-$version.msi")
    if ($asset.Count -ne 1) { throw "Missing unique $arch MSI asset." }
    $msi = Join-Path $OutputDirectory $asset[0].name
    Invoke-WebRequest $asset[0].browser_download_url -OutFile $msi
    if ('sha256:' + (Get-FileHash $msi -Algorithm SHA256).Hash.ToLowerInvariant() -cne $asset[0].digest) {
        throw "Release digest mismatch for $arch MSI."
    }
    & "$msiDirectory/Test-InstallerMetadata.Tests.ps1" -MsiPath $msi -ExpectedVersion $version -ExpectedArchitecture $arch
    $metadata = & "$msiDirectory/Get-InstallerMetadata.ps1" -MsiPath $msi
    $metadata | ConvertTo-Json | Set-Content "$OutputDirectory/msi-$arch.json"
    $manifest = Get-Content "$OutputDirectory/migration-candidate/manifests/g/grate-devs/grate/$version/grate-devs.grate.installer.yaml" -Raw
    foreach ($value in @($metadata.ProductCode, $metadata.UpgradeCode)) {
        if (!$manifest.Contains($value)) { throw "Candidate does not contain inspected $arch MSI identity: $value" }
    }
    Remove-Item -LiteralPath $msi
}
Remove-Item -LiteralPath $tool
Write-Host 'PASS: actual release manifest generation and read-only MSI inspection. No install, upgrade, migration or upstream acceptance was tested.'
