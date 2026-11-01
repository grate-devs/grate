#!/usr/bin/env pwsh
# Native REST manifest data only: no installation, network or filesystem writes.
param(
    [Parameter(Mandatory)]$Inventory,
    [switch]$Both
)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$arch=$Inventory.Architecture
$type=$Inventory.InstallerType
$oldId='erikbra.grate'
$newId='grate-devs.grate'
function Package([string]$Id, [object[]]$Versions) {
    $entries = foreach ($version in $Versions) {
        $extension = if ($type -eq 'zip') { 'zip' } else { 'msi' }
        $installer = [ordered]@{
            Architecture=$arch; InstallerType=$type
            InstallerUrl="https://127.0.0.1:8765/assets/grate-$($version.Version).$extension"
            InstallerSha256=$(if ($type -eq 'zip') { $version.ZipHash } else { $version.MsiHash })
        }
        if ($type -eq 'zip') {
            $installer.Scope='user'
            $installer.NestedInstallerType='portable'
            $installer.NestedInstallerFiles=@(@{RelativeFilePath='grate.exe'; PortableCommandAlias='grate'})
        } else {
            $meta=$version.MsiMetadata
            # Historical manifests retain their actual scope. The corrected MSI
            # intentionally omits optional Scope: WinGet's installed ARP scope
            # differs from its native per-user MSI context (#3011).
            if ([version]$version.Version -lt [version]'2.1.7') { $installer.Scope='user' }
            $bridge=$Id -eq $oldId -and $version.Version -eq '2.1.7'
            $entry=@{DisplayName=$meta.ProductName; Publisher=$(if ($bridge) {'erikbra'} else {$meta.Manufacturer}); DisplayVersion=$meta.ProductVersion}
            if (!$bridge) {
                $installer.ProductCode=$meta.ProductCode
                $entry.ProductCode=$meta.ProductCode
                $entry.UpgradeCode=$meta.UpgradeCode
            }
            $installer.AppsAndFeaturesEntries=@($entry)
            $installer.InstallationMetadata=@{DefaultInstallLocation='%LocalAppData%/erikbra/grate'}
        }
        @{ PackageVersion=$version.Version; DefaultLocale=@{PackageLocale='en-US'; Publisher=$(if ($Id -eq $oldId) {'erikbra'} else {'grate-devs'}); PackageName='grate'; License='MIT'; ShortDescription='grate migration lifecycle test'}; Installers=@($installer) }
    }
    @{PackageIdentifier=$Id; Versions=@($entries)}
}
$lastOld=if ($Both) {'2.1.7'} else {'2.1.6'}
$packages = @(Package $oldId @($Inventory.Versions | Where-Object { [version]$_.Version -le [version]$lastOld }))
if ($Both) { $packages += Package $newId @($Inventory.Versions | Where-Object { [version]$_.Version -ge [version]'2.1.7' }) }
@{SourceIdentifier='grate-migration-ci'; Packages=$packages}
