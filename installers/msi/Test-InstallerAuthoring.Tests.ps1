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
} finally {
    Remove-Item -LiteralPath $fixture -ErrorAction SilentlyContinue
}
Write-Host 'PASS: MSI directory cleanup and per-user-only ICE91 advisory contract.'
