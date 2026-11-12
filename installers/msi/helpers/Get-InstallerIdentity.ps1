#!/usr/bin/env pwsh
param (
    [Parameter(Mandatory=$true)] [string]$Version,
    [Parameter(Mandatory=$true)] [ValidateSet('x64', 'arm64')] [string]$Architecture,
    [string]$ReleaseVersion = $Version,
    [ValidateSet('All', 'SQLite', 'SQLServer', 'MariaDB', 'PostgreSQL', 'Oracle')]
    [string]$Distribution = 'All'
)
$ErrorActionPreference = 'Stop'
$Architecture = $Architecture.ToLowerInvariant()
$Distribution = @('All', 'SQLite', 'SQLServer', 'MariaDB', 'PostgreSQL', 'Oracle') | Where-Object { $_ -ieq $Distribution }
if ($Version -notmatch '^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$') {
    throw 'MSI identity requires a three-part numeric version.'
}
$number = [version]$Version
if ($number.Major -gt 255 -or $number.Minor -gt 255 -or $number.Build -gt 65535) {
    throw 'MSI version exceeds Windows Installer limits.'
}
$identifier = '(?:0|[1-9][0-9]*|[0-9]*[A-Za-z-][0-9A-Za-z-]*)'
if ($ReleaseVersion -cnotmatch ('^' + [regex]::Escape($Version) + '(?:-' + $identifier + '(?:\.' + $identifier + ')*)?$')) {
    throw 'ReleaseVersion must be the numeric MSI version, optionally followed by valid SemVer prerelease identifiers; build metadata is not a release identity.'
}
$contract = Get-Content -LiteralPath (Join-Path $PSScriptRoot '../identity-contract.json') -Raw | ConvertFrom-Json
# RFC 9562 UUIDv5: namespace UUID in network order plus the UTF-8 name. The same
# full release/architecture has a reproducible ProductCode. Stable UUID names
# remain unchanged; prerelease suffixes distinguish packages, not MSI ordering.
# UpgradeCodes remain family constants.
function New-IdentityGuid {
    param(
        [string]$Name
    )

    $namespace = ([Guid]$contract.ProductCodeNamespace).ToByteArray($true)
    $nameBytes = [Text.Encoding]::UTF8.GetBytes($Name)
    $hash = [Security.Cryptography.SHA1]::HashData([byte[]]($namespace + $nameBytes))
    $bytes = [byte[]]$hash[0..15]
    $bytes[6] = ($bytes[6] -band 0x0f) -bor 0x50
    $bytes[8] = ($bytes[8] -band 0x3f) -bor 0x80
    [Guid]::new($bytes, $true).ToString('B').ToUpperInvariant()
}

# The published All name, path and component GUIDs are compatibility contracts.
# Slim names use a separate, versioned contract prefix, with one upgrade family
# per profile/architecture and one ProductCode per full release in that family.
$productName = $contract.ProductName
$packageId = 'grate'
$productIdentityName = $contract.ProductCodeNamePrefix + $Architecture + '/' + $ReleaseVersion
$upgradeCode = $contract.Architectures.$Architecture.UpgradeCode
$executableComponent = 'C544280E-4F9B-443D-BE6D-4A82CFEE3723'
$pathComponent = 'E7507A5D-D78E-4082-BD75-986A11F54E68'
if ($Distribution -cne 'All') {
    $profilePrefix = $contract.DistributionIdentityNamePrefix + $Distribution.ToLowerInvariant()
    $productName = "grate ($Distribution)"
    $packageId = 'grate-' + $Distribution.ToLowerInvariant()
    $productIdentityName = "$profilePrefix/product/win-$Architecture/$ReleaseVersion"
    $upgradeCode = New-IdentityGuid "$profilePrefix/upgrade/win-$Architecture"
    $executableComponent = New-IdentityGuid "$profilePrefix/component/executable"
    $pathComponent = New-IdentityGuid "$profilePrefix/component/path"
}
[pscustomobject]@{
    ProductCode = New-IdentityGuid $productIdentityName
    UpgradeCode = $upgradeCode
    ProductName = $productName
    Manufacturer = $contract.Manufacturer
    LegacyProductCode = $contract.LegacyProductCode
    Version = $Version
    ReleaseVersion = $ReleaseVersion
    IsPrerelease = $ReleaseVersion -cne $Version
    Architecture = $Architecture
    Distribution = $Distribution
    PackageId = $packageId
    ExecutableComponent = $executableComponent
    PathComponent = $pathComponent
    RegistryKey = "Software\Microsoft\erikbra\$packageId"
}
