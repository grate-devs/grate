#!/usr/bin/env pwsh

param (
    [Parameter(Mandatory=$true)] [string] $grateExe,
    [Parameter(Mandatory=$true)] [string] $version,
    [Parameter(Mandatory=$true)] [string] $arch,
    [ValidateSet('All', 'SQLite', 'SQLServer', 'MariaDB')] [string] $Distribution = 'All',
    [string] $OutputDirectory = $PSScriptRoot
)

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true
$grateExe = (Resolve-Path -LiteralPath $grateExe).Path
$OutputDirectory = [IO.Path]::GetFullPath($OutputDirectory)
New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null

$packageName = switch ($Distribution) {
    'All' { 'grate' }
    'SQLite' { 'grate-sqlite' }
    'SQLServer' { 'grate-sqlserver' }
    'MariaDB' { 'grate-mariadb' }
}
$packageFamily = @('grate', 'grate-sqlite', 'grate-sqlserver', 'grate-mariadb')
$conflicts = ($packageFamily | Where-Object { $_ -ne $packageName }) -join ', '
$description = if ($Distribution -eq 'All') { 'SQL for the 20s' } else { "SQL for the 20s ($Distribution only)" }

# Debian sorts ~ before the final version; preserve hyphens inside identifiers.
$pkgVersion = ($version -replace '^([0-9]+\.[0-9]+\.[0-9]+)-', '$1~') + '-1'
$staging = Join-Path ([IO.Path]::GetTempPath()) ('grate-debian-' + [Guid]::NewGuid().ToString('N'))
try {
    $debianDir = Join-Path $staging $packageName
    $binDir = Join-Path $debianDir 'usr/bin'
    New-Item -ItemType Directory -Path $debianDir -Force | Out-Null
    $templateDir = Join-Path $PSScriptRoot 'template'
    Copy-Item -Path "$templateDir/*" -Destination $debianDir -Recurse
    New-Item -ItemType Directory -Path $binDir -Force | Out-Null
    Copy-Item -LiteralPath $grateExe -Destination "$binDir/grate"
    & chmod a+x "$binDir/grate"

    $controlDir = Join-Path $debianDir 'DEBIAN'
    $control = Get-Content -LiteralPath "$controlDir/control" -Raw
    $control.Replace('%%%VERSION%%%', $pkgVersion).Replace('%%%ARCH%%%', $arch).
        Replace('%%%PACKAGE%%%', $packageName).Replace('%%%CONFLICTS%%%', $conflicts).
        Replace('%%%DESCRIPTION%%%', $description) | Set-Content -LiteralPath "$controlDir/control"
    foreach ($script in @('postinst', 'prerm')) {
        (Get-Content -LiteralPath "$controlDir/$script" -Raw).Replace('%%%PACKAGE%%%', $packageName) |
            Set-Content -LiteralPath "$controlDir/$script"
        & chmod 0755 "$controlDir/$script"
    }

    $docRoot = Join-Path $debianDir 'usr/share/doc'
    if ($packageName -ne 'grate') {
        Move-Item -LiteralPath "$docRoot/grate" -Destination "$docRoot/$packageName"
    }
    $manFile = Join-Path $debianDir 'usr/share/man/man1/grate.1'
    $changelog = Join-Path $docRoot "$packageName/changelog"
    & gzip -n --best $manFile
    & gzip -n --best $changelog
    & ln -s changelog.gz "${changelog}.Debian.gz"

    # Keep the SemVer filename expected by callers; Debian reads Version metadata.
    $filename = "${packageName}_${version}-1_${arch}.deb"
    $built = Join-Path $staging $filename
    & dpkg-deb --root-owner-group --build $debianDir $built
    Move-Item -LiteralPath $built -Destination (Join-Path $OutputDirectory $filename) -Force
} finally {
    if (Test-Path -LiteralPath $staging) {
        Remove-Item -LiteralPath $staging -Recurse -Force
    }
}
