#!/usr/bin/env pwsh
$ErrorActionPreference = 'Stop'
$fixture = Join-Path ([IO.Path]::GetTempPath()) ([guid]::NewGuid().ToString() + '.yaml')
$validator = Join-Path $PSScriptRoot 'Test-InstallerCorrelation.ps1'
$content = @'
Installers:
- Architecture: x64
  InstallerUrl: https://example.org/x64.msi
  InstallerSha256: ABCD
  ProductCode: '{11111111-1111-1111-1111-111111111111}'
  AppsAndFeaturesEntries:
  - UpgradeCode: '{22222222-2222-2222-2222-222222222222}'
- InstallerLocale: en-US
  Architecture: arm64
  InstallerUrl: https://example.org/arm64.msi
  InstallerSha256: DCBA
  ProductCode: '{11111111-1111-1111-1111-111111111111}'
  AppsAndFeaturesEntries:
  - UpgradeCode: '{33333333-3333-3333-3333-333333333333}'
ManifestType: installer
'@
$parameters = @{
    ManifestPath = $fixture; InstallerUrl = 'https://example.org/x64.msi'; Architecture = 'x64'
    Sha256 = 'ABCD'; ProductCode = '{11111111-1111-1111-1111-111111111111}'; UpgradeCode = '{22222222-2222-2222-2222-222222222222}'
}
try {
    $content | Set-Content $fixture
    & $validator @parameters
    foreach ($defect in @('UpgradeCode', 'Architecture', 'InstallerSha256', 'duplicate')) {
        $faulty = switch ($defect) {
            UpgradeCode { $content.Replace('22222222-2222-2222-2222-222222222222', '44444444-4444-4444-4444-444444444444').Replace('33333333-3333-3333-3333-333333333333', '22222222-2222-2222-2222-222222222222') }
            Architecture { $content.Replace('- Architecture: x64', '- Architecture: arm64') }
            InstallerSha256 { $content.Replace('InstallerSha256: ABCD', 'InstallerSha256: DCBA') }
            duplicate { $content + "`n- Architecture: x64`n  InstallerUrl: https://example.org/x64.msi`n" }
        }
        $faulty | Set-Content $fixture
        try { & $validator @parameters }
        catch {
            $expected = if ($defect -eq 'duplicate') { '*exactly one installer node*' } else { "*incorrect $defect*" }
            if ($_.Exception.Message -like $expected) { continue }
            throw
        }
        throw "Correlation validator accepted $defect defect."
    }
    $new = $content.Replace("  - UpgradeCode: '{22222222-2222-2222-2222-222222222222}'", "  - Publisher: grate-devs`n    ProductCode: '{11111111-1111-1111-1111-111111111111}'`n    UpgradeCode: '{22222222-2222-2222-2222-222222222222}'")
    $new | Set-Content $fixture
    & $validator @parameters -Policy NewIdentity -Publisher grate-devs
    $bridge = [regex]::Replace($new, '(?m)^\s*(?:- )?(?:ProductCode|UpgradeCode): [^\r\n]*\r?\n', '').Replace('Publisher: grate-devs','Publisher: erikbra')
    $bridge | Set-Content $fixture
    & $validator @parameters -Policy Bridge
    foreach ($defect in @('publisher','rootScope','nodeScope','missingEntryCode','bridgeCode','bridgePublisher')) {
        $policy = if ($defect -like 'bridge*') {'Bridge'} else {'NewIdentity'}
        $faulty = switch ($defect) {
            publisher {$new.Replace('Publisher: grate-devs','Publisher: erikbra')}
            rootScope {"Scope: user`n"+$new}
            nodeScope {$new.Replace('- Architecture: x64',"- Architecture: x64`n  Scope: user")}
            missingEntryCode {$new.Replace("    ProductCode: '{11111111-1111-1111-1111-111111111111}'`n",'')}
            bridgeCode {$bridge.Replace('ManifestType: installer',"ProductCode: '{11111111-1111-1111-1111-111111111111}'`nManifestType: installer")}
            bridgePublisher {$bridge.Replace('Publisher: erikbra','Publisher: grate-devs')}
        }
        $faulty | Set-Content $fixture
        try { & $validator @parameters -Policy $policy }
        catch {
            $expected = switch ($defect) {
                {$_ -in @('publisher','bridgePublisher')} {'*incorrect Publisher*'}
                {$_ -in @('rootScope','nodeScope')} {'*Scope must be omitted*'}
                missingEntryCode {'*installer and AppsAndFeaturesEntries levels*'}
                bridgeCode {'*must not contain strong MSI reference codes*'}
            }
            if ($_.Exception.Message -like $expected) { continue }
            throw
        }
        throw "Correlation validator accepted $defect defect."
    }
} finally { Remove-Item -LiteralPath $fixture -Force -ErrorAction SilentlyContinue }
Write-Host 'PASS: historical/new/bridge MSI correlation contracts; 10 rejected mutations including misplaced UpgradeCode, code aliases, scope and publisher.'
