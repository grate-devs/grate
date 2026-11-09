#!/usr/bin/env pwsh
param(
    [ValidateSet('amd64', 'arm64')]
    [string]$Architecture = 'amd64'
)

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true
if (!$IsLinux) {
    throw 'Debian package verification requires Linux and the Debian packaging tools.'
}
foreach ($tool in @('dpkg', 'dpkg-deb', 'gzip')) {
    Get-Command $tool -ErrorAction Stop | Out-Null
}

function Initialize-PackageFixture {
    param(
        [string]$Directory
    )

    New-Item -ItemType Directory -Path "$Directory/payload" -Force | Out-Null
    Copy-Item -LiteralPath "$PSScriptRoot/Create-Package.ps1", "$PSScriptRoot/template" -Destination $Directory -Recurse
    "#!/bin/sh`nexit 0" | Set-Content -LiteralPath "$Directory/payload/grate"
}

function New-FixturePackage {
    param(
        [string]$Directory,
        [string]$Version,
        [string]$Architecture,
        [string]$Distribution = 'All',
        [string]$OutputDirectory = $Directory
    )

    $packageParameters = @{
        grateExe = "$Directory/payload/grate"
        Version = $Version
        arch = $Architecture
        Distribution = $Distribution
        OutputDirectory = $OutputDirectory
    }
    & "$Directory/Create-Package.ps1" @packageParameters | Out-Host
}

function Assert-PackageField {
    param(
        [string]$Package,
        [string]$Field,
        [string]$Expected
    )

    $actual = (& dpkg-deb --field $Package $Field) -join "`n"
    if ($actual -cne $Expected) {
        throw "Incorrect $Field in ${Package}: '$actual', expected '$Expected'."
    }
}

function Test-PackageVersions {
    param(
        [string]$Directory,
        [string]$Architecture
    )

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
        New-FixturePackage -Directory $Directory -Version $version -Architecture $Architecture
        $package = "$Directory/grate_${version}-1_${Architecture}.deb"
        if (!(Test-Path -LiteralPath $package)) {
            throw "Missing SemVer-named package: $package"
        }
        Assert-PackageField -Package $package -Field Version -Expected $cases[$version]
        Assert-PackageField -Package $package -Field Architecture -Expected $Architecture
        $versions[$version] = & dpkg-deb --field $package Version
    }

    # Use Debian's real comparison against metadata from the generated packages.
    & dpkg --compare-versions $versions['2.1.9'] lt $versions['2.2.0-rc.1']
    & dpkg --compare-versions $versions['2.2.0-rc.1'] lt $versions['2.2.0-rc.2']
    & dpkg --compare-versions $versions['2.2.0-rc.2'] lt $versions['2.2.0-rc.10']
    & dpkg --compare-versions $versions['2.2.0-rc.10'] lt $versions['2.2.0']
    & dpkg --compare-versions $versions['2.2.0-rc-extra.1'] lt $versions['2.2.0']
}

function Assert-DistributionMetadata {
    param(
        [string]$Package,
        [string]$Distribution,
        [string]$PackageId,
        [string]$Architecture,
        [string[]]$PackageFamily
    )

    Assert-PackageField -Package $Package -Field Package -Expected $PackageId
    Assert-PackageField -Package $Package -Field Version -Expected '2.2.0~rc.1-1'
    Assert-PackageField -Package $Package -Field Architecture -Expected $Architecture
    $expectedConflicts = @($PackageFamily | Where-Object { $_ -cne $PackageId }) -join ', '
    Assert-PackageField -Package $Package -Field Conflicts -Expected $expectedConflicts
    Assert-PackageField -Package $Package -Field Provides -Expected ''

    $description = (& dpkg-deb --field $Package Description) -join "`n"
    if ($Distribution -ne 'All' -and !$description.Contains("($Distribution only)")) {
        throw "Missing provider description for $Distribution."
    }
}

function Assert-DistributionPayload {
    param(
        [string]$Package,
        [string]$PackageId,
        [string]$Directory
    )

    $extracted = Join-Path $Directory "extracted-$PackageId"
    & dpkg-deb --extract $Package $extracted
    & dpkg-deb --control $Package "$extracted/DEBIAN"
    $requiredFiles = @(
        'usr/bin/grate'
        "usr/share/doc/$PackageId/copyright"
        "usr/share/doc/$PackageId/changelog.gz"
        'usr/share/man/man1/grate.1.gz'
    )
    foreach ($file in $requiredFiles) {
        if (!(Test-Path -LiteralPath "$extracted/$file")) {
            throw "Missing $file in $PackageId."
        }
    }
    foreach ($script in @('postinst', 'prerm')) {
        $scriptPath = "$extracted/DEBIAN/$script"
        $contents = Get-Content -LiteralPath $scriptPath -Raw
        if ($contents.Contains('%%%') -or !$contents.Contains("/usr/doc/$PackageId")) {
            throw "Incorrect $script documentation path for $PackageId."
        }
        & sh -n $scriptPath
    }
}

function Test-DistributionPackages {
    param(
        [string]$Directory,
        [string]$Architecture
    )

    $distributionIds = [ordered]@{
        'All' = 'grate'
        'SQLite' = 'grate-sqlite'
        'SQLServer' = 'grate-sqlserver'
        'MariaDB' = 'grate-mariadb'
        'PostgreSQL' = 'grate-postgresql'
        'Oracle' = 'grate-oracle'
    }
    $output = Join-Path $Directory 'distribution packages'
    foreach ($distribution in $distributionIds.Keys) {
        $packageId = $distributionIds[$distribution]
        $buildParameters = @{
            Directory = $Directory
            Version = '2.2.0-rc.1'
            Architecture = $Architecture
            Distribution = $distribution
            OutputDirectory = $output
        }
        New-FixturePackage @buildParameters
        $package = "$output/${packageId}_2.2.0-rc.1-1_${Architecture}.deb"
        if (!(Test-Path -LiteralPath $package)) {
            throw "Missing distribution package: $package"
        }
        $metadataParameters = @{
            Package = $package
            Distribution = $distribution
            PackageId = $packageId
            Architecture = $Architecture
            PackageFamily = @($distributionIds.Values)
        }
        Assert-DistributionMetadata @metadataParameters
        Assert-DistributionPayload -Package $package -PackageId $packageId -Directory $Directory
    }
}

$root = Join-Path ([IO.Path]::GetTempPath()) ('grate-debian-version-' + [Guid]::NewGuid().ToString('N'))
try {
    Initialize-PackageFixture -Directory $root
    Test-PackageVersions -Directory $root -Architecture $Architecture
    Test-DistributionPackages -Directory $root -Architecture $Architecture
    if (Test-Path -LiteralPath "$root/debian") {
        throw 'Package recipe left shared staging in its source directory.'
    }
} finally {
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
}
Write-Host "PASS: $Architecture Debian versions, distribution metadata, conflicts, payloads and documentation."
