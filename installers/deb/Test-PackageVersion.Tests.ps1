#!/usr/bin/env pwsh
param (
    [ValidateSet('amd64', 'arm64')] [string]$Architecture = 'amd64'
)

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true
if (!$IsLinux) { throw 'Debian package verification requires Linux and the Debian packaging tools.' }
foreach ($tool in @('dpkg', 'dpkg-deb', 'gzip')) { Get-Command $tool -ErrorAction Stop | Out-Null }

$root = Join-Path ([IO.Path]::GetTempPath()) ('grate-debian-version-' + [Guid]::NewGuid().ToString('N'))
try {
    New-Item -ItemType Directory -Path "$root/payload" -Force | Out-Null
    Copy-Item -LiteralPath "$PSScriptRoot/Create-Package.ps1", "$PSScriptRoot/template" -Destination $root -Recurse
    "#!/bin/sh`nexit 0" | Set-Content "$root/payload/grate"

    # Known metadata expectations, independent of the conversion under test.
    $cases = [ordered]@{
        '2.1.9' = '2.1.9-1'
        '2.2.0-rc.1' = '2.2.0~rc.1-1'
        '2.2.0-rc.2' = '2.2.0~rc.2-1'
        '2.2.0-rc.10' = '2.2.0~rc.10-1'
        '2.2.0' = '2.2.0-1'
        '2.2.0-rc-extra.1' = '2.2.0~rc-extra.1-1'
    }
    $versions = @{}
    foreach ($version in $cases.Keys) {
        & "$root/Create-Package.ps1" -grateExe "$root/payload/grate" -version $version -arch $Architecture | Out-Host
        $package = "$root/grate_${version}-1_${Architecture}.deb"
        if (!(Test-Path -LiteralPath $package)) { throw "Missing SemVer-named package: $package" }
        $actual = & dpkg-deb --field $package Version
        if ($actual -cne $cases[$version]) { throw "Debian Version for $version was '$actual', expected '$($cases[$version])'." }
        $actualArchitecture = & dpkg-deb --field $package Architecture
        if ($actualArchitecture -cne $Architecture) { throw "Incorrect Debian Architecture: $actualArchitecture" }
        $versions[$version] = $actual
    }

    $distributionIds = [ordered]@{
        'All' = 'grate'
        'SQLite' = 'grate-sqlite'
        'SQLServer' = 'grate-sqlserver'
        'MariaDB' = 'grate-mariadb'
        'PostgreSQL' = 'grate-postgresql'
        'Oracle' = 'grate-oracle'
    }
    $output = Join-Path $root 'distribution packages'
    foreach ($distribution in $distributionIds.Keys) {
        $id = $distributionIds[$distribution]
        & "$root/Create-Package.ps1" -grateExe "$root/payload/grate" -version '2.2.0-rc.1' -arch $Architecture `
            -Distribution $distribution -OutputDirectory $output | Out-Host
        $package = "$output/${id}_2.2.0-rc.1-1_${Architecture}.deb"
        if (!(Test-Path -LiteralPath $package)) { throw "Missing distribution package: $package" }
        if ((& dpkg-deb --field $package Package) -cne $id) { throw "Incorrect Package for $distribution." }
        if ((& dpkg-deb --field $package Version) -cne '2.2.0~rc.1-1') { throw "Incorrect Version for $distribution." }
        $expectedConflicts = @($distributionIds.Values | Where-Object { $_ -ne $id })
        $actualConflicts = ((& dpkg-deb --field $package Conflicts) -split ', ')
        if (($actualConflicts -join ',') -cne ($expectedConflicts -join ',')) { throw "Incorrect Conflicts for $distribution." }
        if ((& dpkg-deb --field $package Provides)) { throw "Unexpected Provides for $distribution." }
        $actualDescription = (& dpkg-deb --field $package Description) -join "`n"
        if ($distribution -ne 'All' -and !$actualDescription.Contains("($distribution only)")) {
            throw "Missing provider description for $distribution."
        }
        $extracted = Join-Path $root "extracted-$id"
        & dpkg-deb --extract $package $extracted
        & dpkg-deb --control $package "$extracted/DEBIAN"
        foreach ($file in @('usr/bin/grate', "usr/share/doc/$id/copyright", "usr/share/doc/$id/changelog.gz", 'usr/share/man/man1/grate.1.gz')) {
            if (!(Test-Path -LiteralPath "$extracted/$file")) { throw "Missing $file in $distribution." }
        }
        foreach ($script in @('postinst', 'prerm')) {
            $contents = Get-Content -LiteralPath "$extracted/DEBIAN/$script" -Raw
            if ($contents.Contains('%%%') -or !$contents.Contains("/usr/doc/$id")) { throw "Incorrect $script documentation path for $distribution." }
            & sh -n "$extracted/DEBIAN/$script"
        }
    }
    if (Test-Path -LiteralPath "$root/debian") { throw 'Package recipe left shared staging in its source directory.' }

    # Use Debian's real comparison against metadata from the generated packages.
    & dpkg --compare-versions $versions['2.1.9'] lt $versions['2.2.0-rc.1']
    & dpkg --compare-versions $versions['2.2.0-rc.1'] lt $versions['2.2.0-rc.2']
    & dpkg --compare-versions $versions['2.2.0-rc.2'] lt $versions['2.2.0-rc.10']
    & dpkg --compare-versions $versions['2.2.0-rc.10'] lt $versions['2.2.0']
    & dpkg --compare-versions $versions['2.2.0-rc-extra.1'] lt $versions['2.2.0']
} finally {
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
}
Write-Host "PASS: $Architecture Debian versions, distribution metadata, conflicts, payloads and documentation."
