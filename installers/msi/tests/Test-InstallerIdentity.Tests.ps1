#!/usr/bin/env pwsh
$ErrorActionPreference = 'Stop'
$helper = Join-Path $PSScriptRoot '../helpers/Get-InstallerIdentity.ps1'
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

# Independently computed Python uuid5 vectors. Stable identity remains byte-for-
# byte compatible; rc1/rc2/final differ without pretending MSI orders SemVer.
$releases=@(
    @('x64','2.2.0','{15A28EBE-4095-578B-91C9-C01751DE3E40}'),
    @('x64','2.2.0-rc.1','{81B73976-9216-5FAF-ADC7-30D18AAAEE40}'),
    @('x64','2.2.0-rc.2','{4698E8D2-0DCF-5FB8-B85D-5D99E6638B7B}'),
    @('arm64','2.2.0','{D978F3F9-84B7-5595-BCEB-79013DA47062}'),
    @('arm64','2.2.0-rc.1','{E510F501-1C96-5554-9801-4C5AC1930494}'),
    @('arm64','2.2.0-rc.2','{DB4B4F22-D170-5BE5-9AED-9EFF9F3CF1AB}')
)
foreach ($release in $releases) {
    $actual=& $helper -Version '2.2.0' -ReleaseVersion $release[1] -Architecture $release[0]
    $stable=& $helper -Version '2.2.0' -Architecture $release[0]
    if ($actual.ProductCode -cne $release[2] -or $actual.ReleaseVersion -cne $release[1] -or
        $actual.Version -cne '2.2.0' -or $actual.UpgradeCode -cne $stable.UpgradeCode -or
        $actual.IsPrerelease -ne ($release[1] -ne '2.2.0')) { throw 'Prerelease identity violated the full-version or unchanged stable-family contract.' }
}
foreach ($release in @('2.2.1-rc.1','2.2.0-01','2.2.0-rc..1','2.2.0+sha','2.2.0-rc.1+sha','2.2.0-')) {
    $rejected=$false
    try { & $helper -Version '2.2.0' -ReleaseVersion $release -Architecture x64 | Out-Null } catch { $rejected=$_.Exception.Message -like 'ReleaseVersion must*' }
    if (!$rejected) { throw "Invalid or mismatched release identity accepted: $release" }
}
Write-Host 'PASS: six independent full-version ProductCodes, unchanged stable identities/families and six invalid release identities.'
