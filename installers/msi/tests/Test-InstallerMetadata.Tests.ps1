#!/usr/bin/env pwsh

param (
    [Parameter(Mandatory=$true)] [string]$MsiPath,
    [Parameter(Mandatory=$true)] [string]$ExpectedVersion,
    [Parameter(Mandatory=$true)] [ValidateSet('x64', 'arm64')] [string]$ExpectedArchitecture,
    [string]$ExpectedReleaseVersion = $ExpectedVersion,
    [ValidateSet('All', 'SQLite', 'SQLServer', 'MariaDB', 'PostgreSQL', 'Oracle')]
    [string]$Distribution = 'All',
    [switch]$Historical
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$reader = Join-Path $PSScriptRoot '../helpers/Get-InstallerMetadata.ps1'
$hash = (Get-FileHash -LiteralPath $MsiPath -Algorithm SHA256).Hash
$metadata = & $reader -MsiPath $MsiPath
$identity = & (Join-Path $PSScriptRoot '../helpers/Get-InstallerIdentity.ps1') -Version $ExpectedVersion -Architecture $ExpectedArchitecture -ReleaseVersion $ExpectedReleaseVersion -Distribution $Distribution
$expectations = @{
    ProductCode = $identity.ProductCode
    UpgradeCode = $identity.UpgradeCode
    ProductName = $identity.ProductName
    Distribution = $identity.Distribution
    Manufacturer = $identity.Manufacturer
    ProductVersion = $ExpectedVersion
    ReleaseVersion = $ExpectedReleaseVersion
    Platform = $ExpectedArchitecture
}
if ($Historical) {
    if ($Distribution -ne 'All') {
        throw 'Only the All distribution has historical MSI products.'
    }
    $expectations.ProductCode = $identity.LegacyProductCode
    $expectations.Manufacturer = 'erikbra'
    # Published legacy Arm64 payloads were also wrapped in x64 MSI databases.
    $expectations.Platform = 'x64'
    $expectations.Remove('UpgradeCode')
    $expectations.Remove('ReleaseVersion')
    $expectations.Remove('Distribution')
}
foreach ($expected in $expectations.GetEnumerator()) {
    if ($metadata.($expected.Key) -cne $expected.Value) {
        throw "Unexpected $($expected.Key): $($metadata.($expected.Key)); expected $($expected.Value)."
    }
}
foreach ($name in @('UpgradeCode', 'PackageCode')) {
    $parsed = [Guid]::Empty
    if (![Guid]::TryParse($metadata.$name, [ref]$parsed) -or $parsed -eq [Guid]::Empty) {
        throw "The inspected MSI must have a nonempty $name GUID."
    }
}
if ($metadata.AllUsers -or $metadata.MsiInstallPerUser) { throw 'The MSI must preserve the per-user-only installation context.' }
if ((Get-FileHash -LiteralPath $MsiPath -Algorithm SHA256).Hash -ne $hash) { throw 'Read-only metadata inspection changed the MSI.' }

$invalidMsi = Join-Path ([IO.Path]::GetTempPath()) ([Guid]::NewGuid().ToString() + '.msi')
try {
    'This is not a Windows Installer database.' | Set-Content -LiteralPath $invalidMsi
    $rejected = $false
    try { & $reader -MsiPath $invalidMsi | Out-Null } catch { $rejected = $true }
    if (!$rejected) { throw 'Metadata inspection must reject an invalid MSI database.' }
} finally { Remove-Item -LiteralPath $invalidMsi -Force -ErrorAction SilentlyContinue }

Write-Host "PASS: read-only $ExpectedArchitecture MSI metadata, released identity, per-user context and invalid MSI rejection. Installation/upgrade were not run."
