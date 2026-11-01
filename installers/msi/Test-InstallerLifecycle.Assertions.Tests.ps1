#!/usr/bin/env pwsh
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'InstallerLifecycle.Assertions.ps1')

function Assert-Rejected([scriptblock]$Action, [string]$ExpectedMessage) {
    try { & $Action } catch {
        if ($_.Exception.Message -like $ExpectedMessage) { return }
        throw
    }
    throw "Expected assertion rejection: $ExpectedMessage"
}

$root = Join-Path ([IO.Path]::GetTempPath()) ('grate-msi-assertions-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory $root | Out-Null
try {
    Assert-MsiRegistration -State 5 -Version '0.0.2' -AssignmentType 0 -ExpectedVersion '0.0.2'
    Assert-Rejected { Assert-MsiRegistration -State -1 -Version '0.0.2' -AssignmentType 0 -ExpectedVersion '0.0.2' } '*product state*'
    Assert-Rejected { Assert-MsiRegistration -State 5 -Version '0.0.1' -AssignmentType 0 -ExpectedVersion '0.0.2' } '*registered MSI version*'
    Assert-Rejected { Assert-MsiRegistration -State 5 -Version '0.0.2' -AssignmentType 1 -ExpectedVersion '0.0.2' } '*per-user*'

    $expected = Join-Path $root 'expected.exe'
    $installed = Join-Path $root 'installed.exe'
    Set-Content $expected 'new payload'
    Copy-Item $expected $installed
    Assert-MsiPayload $installed $expected
    Set-Content $installed 'old payload'
    Assert-Rejected { Assert-MsiPayload $installed $expected } '*does not match*'
    Remove-Item $installed
    Assert-Rejected { Assert-MsiPayload $installed $expected } '*missing*'

    $removed = Join-Path $root 'removed-installation'
    Assert-MsiUninstalled -State -1 -InstallDirectory $removed -MarkerPresent $false
    Assert-Rejected { Assert-MsiUninstalled -State 5 -InstallDirectory $removed -MarkerPresent $false } '*remains registered*'
    Assert-Rejected { Assert-MsiUninstalled -State -1 -InstallDirectory $removed -MarkerPresent $true } '*registry marker*'
    New-Item -ItemType Directory $removed | Out-Null
    Assert-Rejected { Assert-MsiUninstalled -State -1 -InstallDirectory $removed -MarkerPresent $false } '*directory remains*'

    $data = Join-Path $root 'user.db'
    Set-Content $data 'migration data'
    $hash = (Get-FileHash $data -Algorithm SHA256).Hash
    Assert-MsiDataPreserved $data $hash
    Set-Content $data 'changed data'
    Assert-Rejected { Assert-MsiDataPreserved $data $hash } '*User data changed*'
    Remove-Item $data
    Assert-Rejected { Assert-MsiDataPreserved $data $hash } '*User data was removed*'

    if ((Get-MsiUpgradeVersion -PackageVersion '0.0.1' -PayloadVersion '2.1.7.0') -ne '2.1.8') { throw 'Payload-relative upgrade version is wrong.' }
    if ((Get-MsiUpgradeVersion -PackageVersion '3.0.4' -PayloadVersion '2.1.7.0') -ne '3.0.5') { throw 'Package-relative upgrade version is wrong.' }
} finally {
    Remove-Item -LiteralPath $root -Recurse -Force
}
Write-Host 'PASS: MSI assertions reject wrong registration/version/scope, stale payload, incomplete uninstall and damaged user data.'
