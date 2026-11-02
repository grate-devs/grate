#!/usr/bin/env pwsh
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
function Require([bool]$Condition,[string]$Message) { if (!$Condition) { throw $Message } }
$versions=@('2.0.0','2.1.6','2.1.7','2.1.8')
foreach ($type in @('wix','zip')) {
    foreach ($arch in @('x64','arm64')) {
        # Independent identities distinguish an old fixed code/random family
        # from the corrected per-version products/stable family.
        $records=foreach ($v in $versions) {
            $legacy=[version]$v -lt [version]'2.1.7'
            @{Version=$v; ZipHash=('A'*64); MsiHash=('B'*64); MsiMetadata=@{
                ProductCode=$(if($legacy){'{LEGACY-PRODUCT}'}else{"{PRODUCT-$arch-$v}"})
                UpgradeCode=$(if($legacy){"{OLD-FAMILY-$v}"}else{"{NEW-FAMILY-$arch}"})
                ProductName='grate'; Manufacturer=$(if($legacy){'erikbra'}else{'grate-devs'}); ProductVersion=$v
            }}
        }
        $inventory=@{InstallerType=$type; Architecture=$arch; Versions=@($records)}
        $before=& "$PSScriptRoot/New-LifecycleCatalog.ps1" -Inventory $inventory
        Require ($before.Packages.Count -eq 1 -and $before.Packages[0].Versions.Count -eq 2) 'The initial source must contain only historical versions under the old ID.'
        $both=& "$PSScriptRoot/New-LifecycleCatalog.ps1" -Inventory $inventory -Both
        Require ($both.SourceIdentifier -eq $before.SourceIdentifier -and $both.Packages.Count -eq 2) 'Both listings must use the unchanged source identity.'
        $old=$both.Packages | Where-Object PackageIdentifier -eq 'erikbra.grate'
        $new=$both.Packages | Where-Object PackageIdentifier -eq 'grate-devs.grate'
        Require (($old.Versions.PackageVersion -join ',') -eq '2.0.0,2.1.6') 'The old listing must retain only historical identities.'
        Require (($new.Versions.PackageVersion -join ',') -eq '2.1.7,2.1.8') 'The new listing must not alias any historical version.'
        $diagnostic=& "$PSScriptRoot/New-LifecycleCatalog.ps1" -Inventory $inventory -Both -IncludeBridge
        $diagnosticOld=$diagnostic.Packages | Where-Object PackageIdentifier -eq 'erikbra.grate'
        $bridge=($diagnosticOld.Versions | Where-Object PackageVersion -eq '2.1.7').Installers[0]
        foreach ($node in $new.Versions) {
            Require ($node.DefaultLocale.Publisher -eq 'grate-devs') 'New listing publisher mismatch.'
            $installer=$node.Installers[0]
            if ($type -eq 'wix') {
                Require (!$installer.Contains('Scope') -and !$bridge.Contains('Scope')) 'Corrected MSI must omit optional Scope to avoid the installed ARP scope mismatch.'
                Require (!$bridge.Contains('ProductCode') -and !$bridge.AppsAndFeaturesEntries[0].ContainsKey('ProductCode') -and !$bridge.AppsAndFeaturesEntries[0].ContainsKey('UpgradeCode')) 'Old bridge must carry no strong code for the corrected MSI.'
                Require ($bridge.AppsAndFeaturesEntries[0].Publisher -eq 'erikbra') 'Old bridge must retain the old publisher.'
                Require ($installer.ProductCode -eq "{PRODUCT-$arch-$($node.PackageVersion)}") 'New listing must carry the actual version-specific product code.'
                Require ($installer.AppsAndFeaturesEntries[0].UpgradeCode -eq "{NEW-FAMILY-$arch}" -and $installer.AppsAndFeaturesEntries[0].Publisher -eq 'grate-devs') 'New listing must carry only its corrected stable family and actual publisher.'
            } else {
                Require (!$installer.Contains('Scope') -and !$bridge.Contains('Scope') -and $installer.NestedInstallerType -eq 'portable') 'Portable scope must be controlled by WinGet and omitted from the manifest.'
                Require (!$installer.Contains('ProductCode') -and !$installer.Contains('AppsAndFeaturesEntries')) 'Portable nodes must not inherit MSI correlation codes.'
            }
        }
    }
}
Write-Host 'PASS: historical source, simultaneous IDs, MSI bridge scope/correlation and portable catalog contracts (four cases).'
