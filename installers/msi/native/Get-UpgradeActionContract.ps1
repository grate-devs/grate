param(
    [Parameter(Mandatory)]
    [ValidateSet('x64', 'arm64')]
    [string]$Architecture,
    [ValidateSet('All', 'SQLite', 'SQLServer', 'MariaDB', 'PostgreSQL', 'Oracle')]
    [string]$Distribution = 'All'
)

$ErrorActionPreference = 'Stop'
$identityHelper = Join-Path $PSScriptRoot '../helpers/Get-InstallerIdentity.ps1'
$current = & $identityHelper -Version '0.0.1' -Architecture $Architecture -Distribution $Distribution
$families = foreach ($profile in @('All', 'SQLite', 'SQLServer', 'MariaDB', 'PostgreSQL', 'Oracle')) {
    foreach ($platform in @('x64', 'arm64')) {
        $identity = & $identityHelper -Version '0.0.1' -Architecture $platform -Distribution $profile
        "    { L`"$($identity.UpgradeCode)`", L`"$($identity.ProductName)`" },"
    }
}
$allowLegacy = if ($current.Distribution -eq 'All') {
    'true'
} else {
    'false'
}
@"
#define GRATE_LEGACY_PRODUCT_CODE L"$($current.LegacyProductCode)"
#define GRATE_CURRENT_UPGRADE_CODE L"$($current.UpgradeCode)"
#define GRATE_CURRENT_PRODUCT_NAME L"$($current.ProductName)"
#define GRATE_CURRENT_DISTRIBUTION L"$($current.Distribution)"
#define GRATE_ALLOW_LEGACY $allowLegacy
struct GrateFamily { const wchar_t* code; const wchar_t* productName; };
constexpr GrateFamily GRATE_FAMILIES[] = {
$($families -join "`n")
};
"@
