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

. (Join-Path $PSScriptRoot '../helpers/InstallerPayloadPolicy.ps1')
$profiles = @('All', 'SQLite', 'SQLServer', 'MariaDB', 'PostgreSQL', 'Oracle')
$families = @()
$products = @()
foreach ($profile in $profiles) {
    foreach ($architecture in @('x64', 'arm64')) {
        $identity = & $helper -Version '2.1.7' -Architecture $architecture -Distribution $profile
        $next = & $helper -Version '2.1.8' -Architecture $architecture -Distribution $profile
        $rc = & $helper -Version '2.1.7' -ReleaseVersion '2.1.7-rc.1' -Architecture $architecture -Distribution $profile
        $caseVariant = & $helper -Version '2.1.7' -Architecture $architecture.ToUpperInvariant() -Distribution $profile.ToLowerInvariant()
        if ($next.UpgradeCode -cne $identity.UpgradeCode -or $next.ProductCode -ceq $identity.ProductCode -or
            $rc.UpgradeCode -cne $identity.UpgradeCode -or $rc.ProductCode -ceq $identity.ProductCode -or
            $caseVariant.ProductCode -cne $identity.ProductCode -or $caseVariant.Distribution -cne $profile) {
            throw "Unstable MSI profile identity: $profile $architecture."
        }
        $families += $identity.UpgradeCode
        $products += @($identity.ProductCode, $next.ProductCode, $rc.ProductCode)
        $payloadName = if ($profile -eq 'All') {
            'grate database migration'
        } else {
            "grate ($profile)"
        }
        Assert-MsiPayloadIdentity -ProductVersion '2.1.7+commit' -ProductName $payloadName -Identity $identity
        foreach ($wrongProfile in @($profiles | Where-Object { $_ -cne $profile })) {
            $wrongName = if ($wrongProfile -eq 'All') {
                'grate database migration'
            } else {
                "grate ($wrongProfile)"
            }
            $rejected = $false
            try {
                Assert-MsiPayloadIdentity -ProductVersion '2.1.7' -ProductName $wrongName -Identity $identity
            } catch {
                $rejected = $_.Exception.Message -like 'The executable ProductName must match*'
            }
            if (!$rejected) {
                throw "MSI accepted the $wrongProfile payload as $profile."
            }
        }
        foreach ($wrongVersion in @('', '2.1.8', '2.1.7-rc.1')) {
            $rejected = $false
            try {
                Assert-MsiPayloadIdentity -ProductVersion $wrongVersion -ProductName $payloadName -Identity $identity
            } catch {
                $rejected = $_.Exception.Message -like 'The executable ProductVersion must match*'
            }
            if (!$rejected) {
                throw 'MSI accepted a missing or mismatched payload release.'
            }
        }
        $header = & (Join-Path $PSScriptRoot '../native/Get-UpgradeActionContract.ps1') -Architecture $architecture -Distribution $profile
        if ([regex]::Matches($header, '\{ L"\{').Count -ne 12 -or
            !$header.Contains("#define GRATE_CURRENT_UPGRADE_CODE L`"$($identity.UpgradeCode)`"") -or
            !$header.Contains("{ L`"$($identity.UpgradeCode)`", L`"$($identity.ProductName)`" }")) {
            throw 'The native guard must know every profile/architecture and its own upgrade family.'
        }
        $expectedLegacy = if ($profile -eq 'All') {
            'true'
        } else {
            'false'
        }
        if (!$header.Contains("#define GRATE_ALLOW_LEGACY $expectedLegacy")) {
            throw 'Only All can migrate a legacy All MSI.'
        }
    }
}
if (@($families | Select-Object -Unique).Count -ne 12 -or @($products | Select-Object -Unique).Count -ne 36) {
    throw 'MSI distribution, architecture and full release identities must never alias.'
}
$all = & $helper -Version '2.1.7' -Architecture x64
if ($all.PackageId -cne 'grate' -or $all.ProductName -cne 'grate' -or
    $all.RegistryKey -cne 'Software\Microsoft\erikbra\grate' -or
    $all.ExecutableComponent -cne 'C544280E-4F9B-443D-BE6D-4A82CFEE3723' -or
    $all.PathComponent -cne 'E7507A5D-D78E-4082-BD75-986A11F54E68') {
    throw 'The published All MSI component and registry identity changed.'
}
$sqlite = & $helper -Version '2.1.7' -Architecture x64 -Distribution SQLite
if ($sqlite.ProductCode -cne '{52F93309-A095-510F-9162-6F6E06189720}' -or
    $sqlite.UpgradeCode -cne '{74ADAB62-09B5-512B-AE0B-F576DE8C56FE}') {
    throw 'The stable SQLite MSI UUIDv5 identity contract changed.'
}
$rejected = $false
try {
    & $helper -Version '2.1.7' -Architecture x64 -Distribution Unknown | Out-Null
} catch {
    $rejected = $_.Exception.Message -like '*ValidateSet*' -or $_.Exception.Message -like '*does not belong to the set*'
}
if (!$rejected) {
    throw 'An unknown MSI distribution was accepted.'
}
Write-Host 'PASS: 12 stable profile/architecture families, 36 full-release products, native conflict inventory, 60 wrong-profile and 36 wrong-release payload rejections; All identity preserved.'
