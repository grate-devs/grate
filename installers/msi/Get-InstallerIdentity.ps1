#!/usr/bin/env pwsh
param (
    [Parameter(Mandatory=$true)] [string]$Version,
    [Parameter(Mandatory=$true)] [ValidateSet('x64', 'arm64')] [string]$Architecture
)
$ErrorActionPreference = 'Stop'
if ($Version -notmatch '^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$') { throw 'MSI identity requires a stable three-part numeric version.' }
$number = [version]$Version
if ($number.Major -gt 255 -or $number.Minor -gt 255 -or $number.Build -gt 65535) { throw 'MSI version exceeds Windows Installer limits.' }
$contract = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'identity-contract.json') -Raw | ConvertFrom-Json
# RFC 9562 UUIDv5: namespace UUID in network order plus the UTF-8 name. The same
# version/architecture has a reproducible ProductCode; a newer release or the
# other architecture has a different code. UpgradeCodes remain family constants.
$namespace = ([Guid]$contract.ProductCodeNamespace).ToByteArray($true)
$name = [Text.Encoding]::UTF8.GetBytes($contract.ProductCodeNamePrefix + $Architecture + '/' + $Version)
$hash = [Security.Cryptography.SHA1]::HashData([byte[]]($namespace + $name))
$bytes = [byte[]]$hash[0..15]
$bytes[6] = ($bytes[6] -band 0x0f) -bor 0x50
$bytes[8] = ($bytes[8] -band 0x3f) -bor 0x80
[pscustomobject]@{
    ProductCode = [Guid]::new($bytes, $true).ToString('B').ToUpperInvariant()
    UpgradeCode = $contract.Architectures.$Architecture.UpgradeCode
    ProductName = $contract.ProductName
    Manufacturer = $contract.Manufacturer
    LegacyProductCode = $contract.LegacyProductCode
    Version = $Version
    Architecture = $Architecture
}
