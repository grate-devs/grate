#!/usr/bin/env pwsh

$ErrorActionPreference = 'Stop'
$validator = Join-Path $PSScriptRoot 'Test-InstallerAuthoring.ps1'
$templatePath = Join-Path $PSScriptRoot 'grate.wxs'
& $validator -TemplatePath $templatePath

$fixture = Join-Path ([System.IO.Path]::GetTempPath()) ([Guid]::NewGuid().ToString() + '.wxs')
function Assert-Rejected([xml]$Template, [string]$ExpectedMessage) {
    $Template.Save($fixture)
    try {
        & $validator -TemplatePath $fixture
    } catch {
        if ($_.Exception.Message -like $ExpectedMessage) { return }
        throw
    }
    throw "Expected authoring rejection: $ExpectedMessage"
}

try {
    # Original ICE64 defect: a row named ROOTDIRECTORY still targets the containing
    # INSTALLFOLDER when its Directory attribute is missing.
    [xml]$faulty = Get-Content -LiteralPath $templatePath -Raw
    $removal = $faulty.Wix.Product.Directory.Directory.Directory.Directory.Component.RemoveFolder |
        Where-Object Directory -eq 'ROOTDIRECTORY'
    $removal.RemoveAttribute('Directory')
    $removal.SetAttribute('Id', 'ROOTDIRECTORY')
    Assert-Rejected $faulty '*explicitly remove ROOTDIRECTORY*'

    foreach ($attribute in @('InstallScope', 'InstallPrivileges')) {
        [xml]$faulty = Get-Content -LiteralPath $templatePath -Raw
        $faulty.Wix.Product.Package.SetAttribute($attribute, $(if ($attribute -eq 'InstallScope') { 'perMachine' } else { 'elevated' }))
        Assert-Rejected $faulty '*requires a perUser, limited-privilege MSI*'
    }
    foreach ($propertyId in @('ALLUSERS', 'MSIINSTALLPERUSER')) {
        [xml]$faulty = Get-Content -LiteralPath $templatePath -Raw
        $property = $faulty.CreateElement('Property', $faulty.DocumentElement.NamespaceURI)
        $property.SetAttribute('Id', $propertyId)
        $property.SetAttribute('Value', '1')
        $null = $faulty.Wix.Product.AppendChild($property)
        Assert-Rejected $faulty '*must not author ALLUSERS or MSIINSTALLPERUSER*'
    }

    # Changing the WinGet publisher must not silently create a different MSI or
    # break Windows Installer/ARP correlation for installed erikbra.grate MSIs.
    $identityChanges = @(
        @('/w:Wix/w:Product', 'Id', '*'),
        @('/w:Wix/w:Product', 'Name', 'grate-devs.grate'),
        @('/w:Wix/w:Product', 'Manufacturer', 'grate-devs'),
        @('/w:Wix/w:Product', 'UpgradeCode', '00000000-0000-0000-0000-000000000001'),
        @('/w:Wix/w:Product/w:Package', 'Manufacturer', 'grate-devs'),
        @("//w:Directory[@Id='ROOTDIRECTORY']", 'Name', 'grate-devs'),
        @("//w:Directory[@Id='INSTALLFOLDER']", 'Name', 'grate-devs.grate'),
        @("//w:Component[@Id='MainExecutable']", 'Guid', '*'),
        @("//w:Component[@Id='PathVariable']", 'Guid', '*'),
        @("//w:Component[@Id='MainExecutable']/w:RegistryValue", 'Root', 'HKLM'),
        @("//w:Component[@Id='MainExecutable']/w:RegistryValue", 'Key', 'Software\Microsoft\grate-devs\grate')
    )
    foreach ($change in $identityChanges) {
        [xml]$faulty = Get-Content -LiteralPath $templatePath -Raw
        $namespaces = [System.Xml.XmlNamespaceManager]::new($faulty.NameTable)
        $namespaces.AddNamespace('w', 'http://schemas.microsoft.com/wix/2006/wi')
        $faulty.SelectSingleNode($change[0], $namespaces).SetAttribute($change[1], $change[2])
        Assert-Rejected $faulty '*must preserve the MSI identity*'
    }
    [xml]$faulty = Get-Content -LiteralPath $templatePath -Raw
    $faulty.Wix.Product.Directory.Directory.SetAttribute('Id', 'ProgramFilesFolder')
    Assert-Rejected $faulty '*must preserve the per-user MSI installation path*'

    foreach ($upgradeElement in @('MajorUpgrade', 'Upgrade')) {
        [xml]$faulty = Get-Content -LiteralPath $templatePath -Raw
        $element = $faulty.CreateElement($upgradeElement, $faulty.DocumentElement.NamespaceURI)
        $null = $faulty.Wix.Product.AppendChild($element)
        Assert-Rejected $faulty '*must preserve the current MSI minor-update contract*'
    }
} finally {
    Remove-Item -LiteralPath $fixture -ErrorAction SilentlyContinue
}
Write-Host 'PASS: MSI directory cleanup, per-user-only ICE91 advisory and WinGet migration identity contract (19 rejected mutations).'
