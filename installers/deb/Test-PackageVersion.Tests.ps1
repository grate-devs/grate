#!/usr/bin/env pwsh
param (
    [ValidateSet('amd64', 'arm64')] [string]$Architecture = 'amd64'
)

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true
if (!$IsLinux) { throw 'Debian package verification requires Linux and the Debian packaging tools.' }
foreach ($tool in @('dpkg', 'dpkg-deb', 'fakeroot', 'gzip')) { Get-Command $tool -ErrorAction Stop | Out-Null }

$root = Join-Path ([IO.Path]::GetTempPath()) ('grate-debian-version-' + [Guid]::NewGuid().ToString('N'))
try {
    New-Item -ItemType Directory -Path "$root/payload" -Force | Out-Null
    Copy-Item -LiteralPath "$PSScriptRoot/Create-Package.ps1", "$PSScriptRoot/template" -Destination $root -Recurse
    "#!/bin/sh`nexit 0" | Set-Content "$root/payload/grate"
    'License fixture for package lifecycle verification.' | Set-Content "$root/payload/THIRD-PARTY-NOTICES.txt"

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
        $extracted = Join-Path $root "extracted-$version"
        & dpkg-deb --extract $package $extracted
        $installedNotice = Join-Path $extracted 'usr/share/doc/grate/THIRD-PARTY-NOTICES.txt'
        if (!(Test-Path -LiteralPath $installedNotice) -or
            (Get-FileHash -LiteralPath $installedNotice).Hash -cne (Get-FileHash -LiteralPath "$root/payload/THIRD-PARTY-NOTICES.txt").Hash) {
            throw 'The Debian package must retain the exact published third-party notices.'
        }
    }

    # Use Debian's real comparison against metadata from the generated packages.
    & dpkg --compare-versions $versions['2.1.9'] lt $versions['2.2.0-rc.1']
    & dpkg --compare-versions $versions['2.2.0-rc.1'] lt $versions['2.2.0-rc.2']
    & dpkg --compare-versions $versions['2.2.0-rc.2'] lt $versions['2.2.0-rc.10']
    & dpkg --compare-versions $versions['2.2.0-rc.10'] lt $versions['2.2.0']
    & dpkg --compare-versions $versions['2.2.0-rc-extra.1'] lt $versions['2.2.0']
} finally {
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
}
Write-Host "PASS: $Architecture Debian metadata, SemVer filenames and prerelease-to-stable ordering."
