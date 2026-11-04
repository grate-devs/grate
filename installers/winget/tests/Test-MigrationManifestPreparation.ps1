#!/usr/bin/env pwsh
# Local candidate verification only: no GitHub release lookup or submission.
param (
    [Parameter(Mandatory)] [string]$InventoryPath,
    [Parameter(Mandatory)] [string]$OutputDirectory,
    [string]$Winget,
    [string]$MsiMetadataReader = (Join-Path $PSScriptRoot '../../msi/helpers/Get-InstallerMetadata.ps1')
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot '../helpers/MigrationManifestPolicy.ps1')
$inventory = Get-Content -LiteralPath $InventoryPath -Raw | ConvertFrom-Json
if ($inventory.InstallerType -ne 'wix') { throw 'Candidate manifest preparation requires an MSI lifecycle inventory.' }
$architecture = $inventory.Architecture
$OutputDirectory = [IO.Path]::GetFullPath($OutputDirectory)
$candidates = @($inventory.Versions | Where-Object Version -In @('2.1.7','2.1.8'))
if ($candidates.Count -ne 2) { throw 'Expected both current and next-version local MSI candidates.' }
$summary = @()
foreach ($candidate in $candidates) {
    $version = $candidate.Version
    $hash = (Get-FileHash -LiteralPath $candidate.MsiPath -Algorithm SHA256).Hash
    $zipHash = (Get-FileHash -LiteralPath $candidate.ZipPath -Algorithm SHA256).Hash
    if ($hash -ine $candidate.MsiHash -or $zipHash -ine $candidate.ZipHash) { throw 'Candidate inventory hash does not match its local payload.' }
    $actual = & $MsiMetadataReader -MsiPath $candidate.MsiPath
    $url = "https://127.0.0.1:8765/assets/grate-$version.msi"
    $metadata = [pscustomobject]@{
        Architecture=$architecture; InstallerUrl=$url; Sha256=$hash; ProductCode=$actual.ProductCode
        UpgradeCode=$actual.UpgradeCode; ProductVersion=$actual.ProductVersion; ProductName=$actual.ProductName
        Manufacturer=$actual.Manufacturer; Platform=$actual.Platform
        AllUsers=$actual.AllUsers; MsiInstallPerUser=$actual.MsiInstallPerUser
    }
    # An inherited Scope plus stale upstream AFE data exercises the same bounded
    # policy production uses after wingetcreate updates the published assets.
    $inputYaml = '# yaml-language-server: $schema=https://aka.ms/winget-manifest.installer.1.12.0.schema.json' + "`n" + @"
PackageIdentifier: erikbra.grate
PackageVersion: $version
Scope: user
Installers:
- Architecture: $architecture
  InstallerType: zip
  NestedInstallerType: portable
  NestedInstallerFiles:
  - RelativeFilePath: grate.exe
    PortableCommandAlias: grate
  InstallerUrl: https://127.0.0.1:8765/assets/grate-$version.zip
  InstallerSha256: $zipHash
- Architecture: $architecture
  InstallerType: wix
  Scope: user
  InstallerUrl: $url
  InstallerSha256: $hash
  ProductCode: '$($actual.ProductCode)'
  AppsAndFeaturesEntries:
  - Publisher: erikbra
    UpgradeCode: '$($actual.UpgradeCode)'
ManifestType: installer
ManifestVersion: 1.12.0
"@ + "`n"
    $policy = ConvertTo-WinGetMigrationManifests -InstallerYaml $inputYaml -Version $version -MsiMetadata @($metadata)
    foreach ($identity in @('grate-devs.grate')) {
        $directory = Join-Path $OutputDirectory "$version/$identity"
        if (Test-Path -LiteralPath $directory) { throw "Refusing to overwrite candidate manifest set: $directory" }
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
        $publisher = 'grate-devs'
        $installer = $policy.NewInstallerYaml
        $installer | Set-Content -LiteralPath "$directory/$identity.installer.yaml" -Encoding utf8NoBOM
        ('# yaml-language-server: $schema=https://aka.ms/winget-manifest.version.1.12.0.schema.json' + "`nPackageIdentifier: $identity`nPackageVersion: $version`nDefaultLocale: en-US`nManifestType: version`nManifestVersion: 1.12.0") |
            Set-Content -LiteralPath "$directory/$identity.yaml" -Encoding utf8NoBOM
        ('# yaml-language-server: $schema=https://aka.ms/winget-manifest.defaultLocale.1.12.0.schema.json' + "`nPackageIdentifier: $identity`nPackageVersion: $version`nPackageLocale: en-US`nPublisher: $publisher`nPackageName: grate`nLicense: MIT`nShortDescription: SQL migration runner`nManifestType: defaultLocale`nManifestVersion: 1.12.0") |
            Set-Content -LiteralPath "$directory/$identity.locale.en-US.yaml" -Encoding utf8NoBOM
        & "$PSScriptRoot/Test-InstallerCorrelation.ps1" -ManifestPath "$directory/$identity.installer.yaml" `
            -InstallerUrl $url -Architecture $architecture -ProductCode $actual.ProductCode -UpgradeCode $actual.UpgradeCode `
            -Sha256 $hash -Policy NewIdentity -Publisher $publisher
        if ($Winget) {
            & $Winget validate --manifest $directory --disable-interactivity *>&1 | Tee-Object -FilePath "$directory/schema.log"
            if ($LASTEXITCODE -ne 0) { throw "WinGet schema validation failed for $identity $version." }
        }
        $summary += @{Identity=$identity; Version=$version; Architecture=$architecture; SchemaValidated=[bool]$Winget; ProductCode=$actual.ProductCode; UpgradeCode=$actual.UpgradeCode; Manufacturer=$actual.Manufacturer; AllUsers=$actual.AllUsers; MsiInstallPerUser=$actual.MsiInstallPerUser}
    }
}
$summary | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $OutputDirectory 'summary.json')
Write-Host 'PASS: local corrected MSI candidates produced new-ID manifests with the production policy. See summary.json for schema validation status. No release or submission was performed.'
