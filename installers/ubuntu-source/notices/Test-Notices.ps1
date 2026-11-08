#!/usr/bin/env pwsh
param (
    [Parameter(Mandatory)] [string]$StagedDirectory,
    [string]$BuilderImage = 'grate-ubuntu-source:26.04',
    [string]$RuntimeIdentifier = 'ubuntu.26.04-arm64'
)

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
$stage = (Resolve-Path -LiteralPath $StagedDirectory).Path
$temporary = Join-Path ([IO.Path]::GetTempPath()) "grate-notice-check-$([Guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Path $temporary | Out-Null

function Assert-Condition {
    param (
        [bool]$Condition,
        [string]$Message
    )

    if (!$Condition) {
        throw $Message
    }
}

function Invoke-Generator {
    param (
        [string]$Name,
        [string]$Feed = '/work/grate-mariadb-0.0.1/debian/.build/feed'
    )

    $arguments = @(
        'run', '--rm', '--network=none', '--pull=never',
        '--mount', "type=bind,src=$stage,dst=/work,readonly",
        '--mount', "type=bind,src=$temporary,dst=/test",
        $BuilderImage, 'dotnet', 'msbuild', '/test/helper/Generate-Notices.proj', '-nologo',
        '-p:GrateSourceRoot=/work/grate-mariadb-0.0.1',
        '-p:GratePackagesRoot=/work/grate-mariadb-0.0.1/debian/.nuget-packages',
        '-p:GrateNoticeOutput=/test/output',
        "-p:GrateRuntimeIdentifier=$RuntimeIdentifier",
        "-p:GrateSourceBuiltFeed=$Feed"
    )
    & docker @arguments 2>&1 | Tee-Object -FilePath (Join-Path $temporary "$Name.log") | Out-Host
    return $LASTEXITCODE
}

try {
    $helper = Join-Path $temporary 'helper'
    Copy-Item -LiteralPath $PSScriptRoot -Destination $helper -Recurse
    Assert-Condition ((Invoke-Generator -Name positive) -eq 0) 'Offline notice generation failed against the actual restored source.'
    $notice = Get-Content -LiteralPath "$temporary/output/THIRD-PARTY-NOTICES.txt" -Raw
    foreach ($file in @(
        'text/9148ebecf47ce49421b0adc69192384b0619bcdc22c67b8bb30d26882b8a7db9.txt',
        'text/cfc7749b96f63bd31c3c42b5c471bf756814053e847c10f3eb003417bc523d30.txt',
        'text/8b976f3fbc2575d2b3456ae02c8c438e12e39ba31056d26538b1820dffcbce33.txt'
    )) {
        $original = (Get-Content -LiteralPath (Join-Path $helper $file) -Raw).Replace("`r`n", "`n").Trim()
        Assert-Condition ($notice.Contains($original)) "Original license/full terms missing: $file"
    }
    $inventory = @(Get-Content -LiteralPath "$temporary/output/dependency-licenses.json" -Raw | ConvertFrom-Json)
    foreach ($id in @('Dapper', 'MySqlConnector', 'Microsoft.NET.ILLink.Tasks', "Microsoft.NETCore.App.Host.$RuntimeIdentifier", "Microsoft.NETCore.App.Runtime.$RuntimeIdentifier", 'Microsoft.NETCore.App.Ref')) {
        Assert-Condition (@($inventory | Where-Object id -EQ $id).Count -eq 1) "Expected one notice inventory record for $id"
    }
    foreach ($text in Get-ChildItem -LiteralPath "$temporary/output/installed-packs" -File -Recurse | Where-Object { $_.Name -match '^THIRD-PARTY-NOTICES[.]' }) {
        $original = (Get-Content -LiteralPath $text.FullName -Raw).Replace("`r`n", "`n").Trim()
        Assert-Condition ($notice.Contains($original)) "Resolved pack third-party notices omitted: $($text.FullName)"
    }
    Assert-Condition ($notice.Contains('Ubuntu SDK distribution licenses and notices')) 'Actual distribution copyright/license evidence is missing.'
    $hashes = @(Get-Content -LiteralPath "$temporary/output/apphost-sha256.txt")
    Assert-Condition ($hashes.Count -eq 2 -and $hashes[0] -match '^installed=[A-F0-9]{64}$' -and $hashes[1] -match '^source-built-feed=[A-F0-9]{64}$') 'Both selected installed and supplier-feed host hashes must be recorded.'
    Add-Content -LiteralPath "$helper/text/cfc7749b96f63bd31c3c42b5c471bf756814053e847c10f3eb003417bc523d30.txt" -Value 'tampered'
    Assert-Condition ((Invoke-Generator -Name changed-license) -ne 0) 'Altered source license evidence was accepted.'
    Assert-Condition ((Get-Content -LiteralPath "$temporary/changed-license.log" -Raw).Contains('Source license cache hash mismatch: Dapper/2.1.89')) 'Modified-license failure occurred for the wrong reason.'
    New-Item -ItemType Directory -Path "$temporary/empty-feed" | Out-Null
    Assert-Condition ((Invoke-Generator -Name missing-pack -Feed /test/empty-feed) -ne 0) 'Missing source-built SDK pack evidence was accepted.'
    Assert-Condition ((Get-Content -LiteralPath "$temporary/missing-pack.log" -Raw).Contains('Expected exact source-built SDK pack')) 'Missing-pack failure occurred for the wrong reason.'
    Write-Host 'Notice checks passed: original/full license texts, resolved runtime/apphost/ref and linker coverage, pack TPNs, actual distro evidence, altered-license and missing-pack rejection.'
}
finally {
    Remove-Item -LiteralPath $temporary -Recurse -Force
}
