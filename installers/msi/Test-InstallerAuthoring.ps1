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
