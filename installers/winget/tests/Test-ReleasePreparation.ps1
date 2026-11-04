#!/usr/bin/env pwsh
param (
    [Parameter(Mandatory)] [string]$OutputDirectory
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
if (!$IsWindows) { throw 'Real WinGet preparation and MSI inspection require Windows. No installation is performed.' }
$OutputDirectory = [IO.Path]::GetFullPath($OutputDirectory)
New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null

# Fixed release input provides preparation evidence independent of the latest
# release. wingetcreate still selects the current upstream manifest template.
# This is not a release/publishing workflow.
$version = '2.1.6'
$tool = Join-Path $OutputDirectory 'wingetcreate.exe'
Invoke-WebRequest 'https://github.com/microsoft/winget-create/releases/download/v1.12.13.0/wingetcreate.exe' -OutFile $tool
if ((Get-FileHash $tool -Algorithm SHA256).Hash -ne '24042BD37915805615E6CF969AC57C6439124C3FE85823327F5F3FB24BD9FFEA') {
    throw 'wingetcreate checksum does not match the pinned release.'
}
$helper = Join-Path $PSScriptRoot '../Create-Installer.ps1'
& $helper -version $version -wingetCreate $tool -outputDirectory "$OutputDirectory/accepted-identity" *>&1 |
    Tee-Object -FilePath "$OutputDirectory/update.log"
# This historical release must remain available under its accepted ID, but must
# never become the new identity: its MSI publisher/codes predate the contract.
$rejected = $false
try {
    & $helper -version $version -wingetCreate $tool -outputDirectory "$OutputDirectory/migration-candidate" -PrepareMigration *>&1 |
        Tee-Object -FilePath "$OutputDirectory/migration.log"
} catch {
    if ($_.Exception.Message -notlike '*corrected*MSI*actual grate-devs publisher*') { throw }
    $_.Exception.Message | Set-Content "$OutputDirectory/migration-rejection.log"
    $rejected = $true
}
if (!$rejected -or (Test-Path "$OutputDirectory/migration-candidate/manifests")) { throw 'Historical MSI migration was not rejected cleanly.' }

$msiDirectory = Join-Path $PSScriptRoot '../../msi'
$requestHeaders = @{ Accept = 'application/vnd.github+json' }
if ($env:GH_TOKEN) { $requestHeaders.Authorization = "Bearer $env:GH_TOKEN" }
$release = Invoke-RestMethod "https://api.github.com/repos/grate-devs/grate/releases/tags/$version" -Headers $requestHeaders
foreach ($arch in @('x64', 'arm64')) {
    $asset = @($release.assets | Where-Object name -CEQ "grate-msi-win-$arch-$version.msi")
    if ($asset.Count -ne 1) { throw "Missing unique $arch MSI asset." }
    $msi = Join-Path $OutputDirectory $asset[0].name
    Invoke-WebRequest $asset[0].browser_download_url -OutFile $msi
    if ('sha256:' + (Get-FileHash $msi -Algorithm SHA256).Hash.ToLowerInvariant() -cne $asset[0].digest) {
        throw "Release digest mismatch for $arch MSI."
    }
    $metadata = & "$msiDirectory/helpers/Get-InstallerMetadata.ps1" -MsiPath $msi
    $metadata | ConvertTo-Json | Set-Content "$OutputDirectory/msi-$arch.json"
    # Release 2.1.6 compiled both MSI wrappers with candle -arch x64. Characterize
    # that historical defect explicitly, without mistaking the asset name or URL
    # override for proof of a native ARM64 installer. Current main fixed authoring.
    & "$msiDirectory/tests/Test-InstallerMetadata.Tests.ps1" -MsiPath $msi -ExpectedVersion $version -ExpectedArchitecture x64 -Historical
    if ($arch -eq 'arm64') {
        Write-Warning 'Historical 2.1.6 arm64-named MSI has x64 installer platform. Native ARM64 compatibility remains unverified.'
    }
    & "$PSScriptRoot/Test-InstallerCorrelation.ps1" `
        -ManifestPath "$OutputDirectory/accepted-identity/manifests/e/erikbra/grate/$version/erikbra.grate.installer.yaml" `
        -InstallerUrl $asset[0].browser_download_url -Architecture $arch `
        -ProductCode $metadata.ProductCode -UpgradeCode $metadata.UpgradeCode `
        -Sha256 ((Get-FileHash $msi -Algorithm SHA256).Hash)
    Remove-Item -LiteralPath $msi
}
Remove-Item -LiteralPath $tool
Write-Host 'PASS: historical release generation/inspection and refusal to migrate its legacy MSI. Local corrected-candidate YAML/schema checks run separately. No installation or upstream submission was performed.'
