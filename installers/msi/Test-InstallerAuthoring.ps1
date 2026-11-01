#!/usr/bin/env pwsh

param (
    [string]$TemplatePath = (Join-Path $PSScriptRoot 'grate.wxs')
)

$ErrorActionPreference = 'Stop'
[xml]$template = Get-Content -LiteralPath $TemplatePath -Raw
$namespaces = [System.Xml.XmlNamespaceManager]::new($template.NameTable)
$namespaces.AddNamespace('w', 'http://schemas.microsoft.com/wix/2006/wi')
$package = $template.SelectSingleNode('/w:Wix/w:Product/w:Package', $namespaces)

# ICE91 is harmless only for a per-user-only installation. Reject any change to
# that contract instead of letting the advisory mask per-machine user-profile files.
if (!$package -or $package.InstallScope -ne 'perUser' -or $package.InstallPrivileges -ne 'limited') {
    throw 'The ICE91 advisory exception requires a perUser, limited-privilege MSI.'
}
if ($template.SelectSingleNode("//w:Property[@Id='ALLUSERS' or @Id='MSIINSTALLPERUSER']", $namespaces)) {
    throw 'The per-user-only MSI must not author ALLUSERS or MSIINSTALLPERUSER.'
}

# RemoveFolder/@Id names a removal row, not its directory. Without Directory,
# WiX defaults to the containing component's directory and leaves ROOTDIRECTORY.
foreach ($directoryId in @('INSTALLFOLDER', 'ROOTDIRECTORY')) {
    $directory = $template.SelectSingleNode("//w:Directory[@Id='$directoryId']", $namespaces)
    $removals = @($template.SelectNodes("//w:RemoveFolder[@Directory='$directoryId' and (@On='uninstall' or @On='both')]", $namespaces))
    if (!$directory -or $removals.Count -ne 1) {
        throw "The MSI must explicitly remove $directoryId exactly once on uninstall."
    }
}

# The WinGet package identifier is independent of the MSI identity. Preserve the
# released MSI contract while preparing the new WinGet listing. Changing these
# values needs a separately verified installer migration, not a publisher rename.
$identityAttributes = @(
    @('/w:Wix/w:Product', 'Id', 'E281998A-D8A2-4926-AAA3-066EFA4B2E74'),
    @('/w:Wix/w:Product', 'Name', 'grate'),
    @('/w:Wix/w:Product', 'Manufacturer', 'erikbra'),
    @('/w:Wix/w:Product', 'UpgradeCode', '%%%UPGRADECODE%%%'),
    @('/w:Wix/w:Product/w:Package', 'Manufacturer', 'erikbra'),
    @("//w:Directory[@Id='ROOTDIRECTORY']", 'Name', 'erikbra'),
    @("//w:Directory[@Id='INSTALLFOLDER']", 'Name', 'grate'),
    @("//w:Component[@Id='MainExecutable']", 'Guid', 'C544280E-4F9B-443D-BE6D-4A82CFEE3723'),
    @("//w:Component[@Id='PathVariable']", 'Guid', 'E7507A5D-D78E-4082-BD75-986A11F54E68'),
    @("//w:Component[@Id='MainExecutable']/w:RegistryValue", 'Root', 'HKCU'),
    @("//w:Component[@Id='MainExecutable']/w:RegistryValue", 'Key', 'Software\Microsoft\erikbra\grate')
)
foreach ($contract in $identityAttributes) {
    $node = $template.SelectSingleNode($contract[0], $namespaces)
    if (!$node -or $node.GetAttribute($contract[1]) -cne $contract[2]) {
        throw "The WinGet migration must preserve the MSI identity: $($contract[0])/@$($contract[1])."
    }
}
$directory = $template.SelectSingleNode("//w:Directory[@Id='INSTALLFOLDER']", $namespaces)
if ($directory.ParentNode.Id -ne 'ROOTDIRECTORY' -or $directory.ParentNode.ParentNode.Id -ne 'LocalAppDataFolder') {
    throw 'The WinGet migration must preserve the per-user MSI installation path.'
}
# Existing builders generated a new UpgradeCode for each build. Adding a single
# MajorUpgrade element cannot discover all those installed releases. Keep the
# current minor-update contract until a separate Windows-tested migration exists.
if ($template.SelectSingleNode('//w:MajorUpgrade | //w:Upgrade', $namespaces)) {
    throw 'The WinGet migration must preserve the current MSI minor-update contract.'
}
