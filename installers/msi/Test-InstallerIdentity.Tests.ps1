#!/usr/bin/env pwsh
$ErrorActionPreference = 'Stop'
$helper = Join-Path $PSScriptRoot 'Get-InstallerIdentity.ps1'
# Independent Python uuid.uuid5(uuid.NAMESPACE_URL, published identity name)
# examples. These distinguish endian errors and accidental per-build GUIDs.
$examples = @(
    @('x64', '2.1.7', '{D60BDC2B-3F3B-53BA-AE6C-92F66776699B}', '{74CFECA2-37A1-5F6C-8739-E5ACA5116FC1}'),
    @('x64', '2.1.8', '{19FC6FF8-C869-5D4B-A712-E68682EC5345}', '{74CFECA2-37A1-5F6C-8739-E5ACA5116FC1}'),
    @('arm64', '2.1.7', '{BFB0EA52-37D5-59D1-A1F1-3CF697A7E598}', '{7A63E6FC-F222-55A6-9F18-1F017FBDCD09}'),
    @('arm64', '2.1.8', '{DB3DE281-61AC-517C-ADEF-53CD4368DEDD}', '{7A63E6FC-F222-55A6-9F18-1F017FBDCD09}')
)
foreach ($example in $examples) {
    $identity = & $helper -Architecture $example[0] -Version $example[1]
    if ($identity.ProductCode -cne $example[2] -or $identity.UpgradeCode -cne $example[3] -or $identity.Manufacturer -cne 'grate-devs') { throw 'MSI identity does not match the independent version/architecture contract.' }
    $repeated = & $helper -Architecture $example[0] -Version $example[1]
    if ($repeated.ProductCode -ne $identity.ProductCode) { throw 'MSI ProductCode must be reproducible for the same release/architecture.' }
    $variants = @($example[0].ToUpperInvariant(), $(if ($example[0] -eq 'arm64') { 'ArM64' } else { 'X64' }))
    foreach ($variant in $variants) {
        $same = & $helper -Architecture $variant -Version $example[1]
        if ($same.ProductCode -cne $example[2] -or $same.UpgradeCode -cne $example[3] -or $same.Architecture -cne $example[0]) { throw 'Architecture case must not create a second MSI identity for the same release.' }
    }
}
foreach ($version in @('2.1.7-beta', '2.1.7.0', '02.1.7', '256.0.0', '1.256.0', '1.0.65536')) {
    $rejected = $false
    try { & $helper -Architecture x64 -Version $version | Out-Null } catch { $rejected = $true }
    if (!$rejected) { throw "Invalid MSI identity version accepted: $version" }
}
Write-Host 'PASS: deterministic MSI ProductCodes, stable independent architecture families and invalid version rejection.'
