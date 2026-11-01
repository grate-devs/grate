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

# The new product identity has an explicit legacy major-upgrade bridge. Keep the
# filesystem/component contract while deriving product/family identity centrally.
$identityAttributes = @(
    @('/w:Wix/w:Product', 'Id', '%%%PRODUCTCODE%%%'),
    @('/w:Wix/w:Product', 'Name', 'grate'),
    @('/w:Wix/w:Product', 'Manufacturer', 'grate-devs'),
    @('/w:Wix/w:Product', 'UpgradeCode', '%%%UPGRADECODE%%%'),
    @('/w:Wix/w:Product/w:Package', 'Manufacturer', 'grate-devs'),
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
$major = @($template.SelectNodes('//w:MajorUpgrade', $namespaces))
$detect = $template.SelectSingleNode("//w:CustomAction[@Id='DetectLegacyGrate']", $namespaces)
$sequence = $template.SelectSingleNode("//w:InstallExecuteSequence/w:Custom[@Action='DetectLegacyGrate']", $namespaces)
if ($major.Count -ne 1 -or $major[0].Schedule -ne 'afterInstallInitialize' -or !$major[0].DowngradeErrorMessage -or
    !$detect -or $detect.BinaryKey -ne 'GrateUpgradeActions' -or $detect.DllEntry -ne 'DetectLegacyGrate' -or $detect.Execute -ne 'immediate' -or $detect.Return -ne 'check' -or
    !$sequence -or $sequence.After -ne 'FindRelatedProducts' -or $sequence.InnerText.Trim() -ne 'NOT Installed AND NOT WIX_DOWNGRADE_DETECTED' -or
    $template.SelectSingleNode('//w:Upgrade', $namespaces)) {
    throw 'The MSI requires one transactional MajorUpgrade with verified legacy detection after FindRelatedProducts.'
}
