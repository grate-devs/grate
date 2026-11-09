$ErrorActionPreference = 'Stop'
$currentPackage = '@PACKAGE_ID@'
$family = @('grate', 'grate-sqlite', 'grate-sqlserver', 'grate-mariadb', 'grate-postgresql', 'grate-oracle')
if ([string]::IsNullOrWhiteSpace($env:ChocolateyInstall)) {
    throw 'ChocolateyInstall is required to check existing grate command owners.'
}
foreach ($package in $family) {
    if ($package -eq $currentPackage) {
        continue
    }
    $payload = Join-Path $env:ChocolateyInstall "lib/$package/tools/grate.exe"
    if (Test-Path -LiteralPath $payload -PathType Leaf) {
        throw "Uninstall $package before installing $currentPackage; both provide the grate command."
    }
}
