#!/usr/bin/env pwsh
# Contract tests use a release inventory and a recording wingetcreate substitute.
# They exercise argument/output behavior; Windows/tool/schema tests are separate.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$helper = Join-Path $PSScriptRoot 'Create-Installer.ps1'
$state = Join-Path ([IO.Path]::GetTempPath()) ('grate-winget-tests-' + [Guid]::NewGuid().ToString('N'))
$wingetTest = @{ apiCalls = 0; toolCalls = 0; toolExitCode = 0; wrongOutput = $false; arguments = @(); testCount = 0; release = $null }

function New-Release {
    [pscustomobject]@{
        tag_name = '2.1.6'; draft = $false; prerelease = $false; published_at = '2026-07-31T21:00:00Z'
        assets = @(
            'grate-win-x86-self-contained-2.1.6.zip', 'grate-win-x64-self-contained-2.1.6.zip',
            'grate-win-arm64-self-contained-2.1.6.zip', 'grate-msi-win-x64-2.1.6.msi', 'grate-msi-win-arm64-2.1.6.msi'
        ) | ForEach-Object {
            [pscustomobject]@{ name = $_; browser_download_url = "https://github.com/grate-devs/grate/releases/download/2.1.6/$_"; state = 'uploaded'; size = 123 }
        }
    }
}
function Invoke-RestMethod([string]$Uri, [hashtable]$Headers) {
    $wingetTest.apiCalls++
    if ($Uri -cne 'https://api.github.com/repos/grate-devs/grate/releases/tags/2.1.6') { throw "Unexpected API call: $Uri" }
    $wingetTest.release
}
function Invoke-TestWingetCreate {
    $wingetTest.toolCalls++
    # A native executable receives array arguments expanded by PowerShell.
    $wingetTest.arguments = @($args | ForEach-Object { $_ })
    $global:LASTEXITCODE = $wingetTest.toolExitCode
    if ($wingetTest.toolExitCode -ne 0) { return }
    $path = Join-Path $args[($args.IndexOf('-o') + 1)] 'manifests/e/erikbra/grate/2.1.6'
    New-Item -ItemType Directory -Path $path -Force | Out-Null
    $version = if ($wingetTest.wrongOutput) { '2.0.0' } else { '2.1.6' }
    $common = "PackageIdentifier: erikbra.grate`nPackageVersion: $version`n"
    ($common + "DefaultLocale: en-US`nManifestType: version`nManifestVersion: 1.12.0`n") |
        Set-Content (Join-Path $path 'erikbra.grate.yaml')
    ($common + "Publisher: erikbra`nPackageName: grate`nManifestType: defaultLocale`nManifestVersion: 1.12.0`n") |
        Set-Content (Join-Path $path 'erikbra.grate.locale.en-US.yaml')
    # Distinct MSI identity values must survive migration conversion unchanged.
    ($common + "Installers:`n- Architecture: x64`n  ProductCode: '{E281998A-D8A2-4926-AAA3-066EFA4B2E74}'`n  AppsAndFeaturesEntries:`n  - Publisher: erikbra`n    UpgradeCode: '{98CF60F4-3F43-4ACE-B364-ADBCD893A144}'`nManifestType: installer`nManifestVersion: 1.12.0`n") |
        Set-Content (Join-Path $path 'erikbra.grate.installer.yaml')
}
function Assert-True([bool]$Condition, [string]$Message) {
    if (!$Condition) { throw $Message }
}
function Assert-Rejected([hashtable]$Parameters, [string]$Message, [switch]$AllowToolCall) {
    $before = $wingetTest.toolCalls
    if (!$Parameters.ContainsKey('outputDirectory')) { $Parameters.outputDirectory = Join-Path $state ([guid]::NewGuid().ToString('N')) }
    try { & $helper @Parameters -wingetCreate Invoke-TestWingetCreate }
    catch {
        if ($_.Exception.Message -notlike $Message) { throw }
        if (!$AllowToolCall) { Assert-True ($wingetTest.toolCalls -eq $before) 'Rejected input still invoked wingetcreate.' }
        $wingetTest.testCount++
        return
    }
    throw "Expected rejection: $Message"
}

try {
    $wingetTest.release = New-Release
    & $helper -version 2.1.6 -wingetCreate Invoke-TestWingetCreate -outputDirectory "$state/update"
    $expectedUrls = @(
        'https://github.com/grate-devs/grate/releases/download/2.1.6/grate-win-x86-self-contained-2.1.6.zip|x86',
        'https://github.com/grate-devs/grate/releases/download/2.1.6/grate-win-x64-self-contained-2.1.6.zip|x64',
        'https://github.com/grate-devs/grate/releases/download/2.1.6/grate-win-arm64-self-contained-2.1.6.zip|arm64',
        'https://github.com/grate-devs/grate/releases/download/2.1.6/grate-msi-win-x64-2.1.6.msi|x64',
        'https://github.com/grate-devs/grate/releases/download/2.1.6/grate-msi-win-arm64-2.1.6.msi|arm64'
    )
    Assert-True ($wingetTest.arguments[0] -eq 'update' -and $wingetTest.arguments[1] -eq 'erikbra.grate') 'Default must update the accepted identity.'
    Assert-True (($wingetTest.arguments[3..7] -join "`n") -ceq ($expectedUrls -join "`n")) 'The five asset URLs/architectures were not passed intact.'
    Assert-True ('-s' -notin $wingetTest.arguments -and '--submit' -notin $wingetTest.arguments) 'Preparation must not submit.'
    Assert-True ('https://github.com/grate-devs/grate/releases/tag/2.1.6' -in $wingetTest.arguments -and '2026-07-31' -in $wingetTest.arguments) 'Release metadata missing.'
    Assert-True (Test-Path "$state/update/manifests/e/erikbra/grate/2.1.6/erikbra.grate.yaml") 'Legacy output path missing.'
    $wingetTest.testCount++

    & $helper -version 2.1.6 -wingetCreate Invoke-TestWingetCreate -outputDirectory "$state/migration" -PrepareMigration
    $candidate = "$state/migration/manifests/g/grate-devs/grate/2.1.6"
    Assert-True (@(Get-ChildItem $candidate).Count -eq 3) 'Candidate requires exactly three manifests.'
    foreach ($name in @('grate-devs.grate.yaml', 'grate-devs.grate.installer.yaml', 'grate-devs.grate.locale.en-US.yaml')) {
        $text = Get-Content (Join-Path $candidate $name) -Raw
        Assert-True ($text.Contains('PackageIdentifier: grate-devs.grate') -and !$text.Contains('PackageIdentifier: erikbra.grate')) 'Candidate identity was not converted.'
    }
    $installer = Get-Content "$candidate/grate-devs.grate.installer.yaml" -Raw
    Assert-True ($installer.Contains("ProductCode: '{E281998A-D8A2-4926-AAA3-066EFA4B2E74}'") -and $installer.Contains("UpgradeCode: '{98CF60F4-3F43-4ACE-B364-ADBCD893A144}'") -and $installer.Contains('  - Publisher: erikbra')) 'Migration modified MSI ARP identity.'
    Assert-True ((Get-Content "$candidate/grate-devs.grate.locale.en-US.yaml" -Raw).Contains('Publisher: grate-devs')) 'Candidate display publisher missing.'
    Assert-True (!(Test-Path "$state/migration/manifests/e")) 'Candidate must not overwrite historical manifests.'
    $wingetTest.testCount++

    foreach ($unstable in @('2.1.7-beta.1', '2.1.7+build.1', '2.1', '02.1.6')) {
        Assert-Rejected @{ version = $unstable } '*stable three-part version*'
    }
    Assert-Rejected @{ version = '2.1.6'; releaseTag = '2.1.5' } '*matching release tag*'
    Assert-True ($wingetTest.apiCalls -eq 2) 'Invalid versions must fail before API calls.'
    foreach ($flag in @('draft', 'prerelease')) {
        $wingetTest.release = New-Release
        $wingetTest.release.$flag = $true
        Assert-Rejected @{ version = '2.1.6' } '*published stable GitHub release*'
    }
    foreach ($defect in @('missing', 'duplicate', 'empty', 'pending', 'wrongUrl')) {
        $wingetTest.release = New-Release
        switch ($defect) {
            missing { $wingetTest.release.assets = $wingetTest.release.assets[0..3] }
            duplicate { $wingetTest.release.assets += $wingetTest.release.assets[0] }
            empty { $wingetTest.release.assets[0].size = 0 }
            pending { $wingetTest.release.assets[0].state = 'new' }
            wrongUrl { $wingetTest.release.assets[0].browser_download_url = 'https://example.org/wrong.zip' }
        }
        Assert-Rejected @{ version = '2.1.6' } $(if ($defect -eq 'wrongUrl') { '*Unexpected download URL*' } else { '*exactly one uploaded, nonempty release asset*' })
    }
    $wingetTest.release = New-Release
    Assert-Rejected @{ version = '2.1.6'; outputDirectory = "$state/migration"; PrepareMigration = $true } '*Refusing to overwrite*'
    $wingetTest.toolExitCode = 19
    Assert-Rejected @{ version = '2.1.6'; outputDirectory = "$state/failed" } '*wingetcreate failed with exit code 19*' -AllowToolCall
    Assert-True (!(Test-Path "$state/failed")) 'Failed tool left output that could be mistaken for a usable manifest.'
    $wingetTest.toolExitCode = 0
    $wingetTest.wrongOutput = $true
    Assert-Rejected @{ version = '2.1.6'; outputDirectory = "$state/malformed" } '*Unexpected package identity/version*' -AllowToolCall
    Assert-True (!(Test-Path "$state/malformed")) 'Malformed tool output was promoted.'
} finally {
    Remove-Item -LiteralPath $state -Recurse -Force -ErrorAction SilentlyContinue
}
Write-Host "PASS: $($wingetTest.testCount) WinGet preparation contract cases."
