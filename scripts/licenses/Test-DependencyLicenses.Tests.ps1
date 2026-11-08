#!/usr/bin/env pwsh
$ErrorActionPreference = 'Stop'
$root = Join-Path ([IO.Path]::GetTempPath()) ('grate-license-tests-' + [Guid]::NewGuid().ToString('N'))
$repository = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$count = 0

function Require {
    param (
        [bool]$Condition,
        [string]$Message
    )
    if (!$Condition) {
        throw $Message
    }
}

function Write-FixturePackage {
    param (
        [string]$Id,
        [string]$License,
        [string]$Type = 'file'
    )
    $directory = Join-Path $root "packages/$($Id.ToLowerInvariant())/1.0.0"
    New-Item -ItemType Directory -Path $directory -Force | Out-Null
    @"
<package><metadata><id>$Id</id><version>1.0.0</version><authors>Fixture owner</authors><copyright>Original fixture copyright</copyright><license type="$Type">$License</license></metadata></package>
"@ | Set-Content -LiteralPath "$directory/$Id.nuspec" -Encoding utf8NoBOM
    if ($Type -eq 'file') {
        "Original license of $Id. Keep this exact copyright and condition." |
            Set-Content -LiteralPath "$directory/$License" -Encoding utf8NoBOM
    }
    'Nested third-party notice: must survive redistribution.' |
        Set-Content -LiteralPath "$directory/THIRD-PARTY-NOTICES.txt" -Encoding utf8NoBOM
}

function Write-FixtureAssets {
    param (
        [string]$Name,
        [string]$ProjectPath,
        [bool]$DownloadPack = $false
    )
    $libraries = [ordered]@{
        'Fixture.Primary/1.0.0' = @{
            type = 'package'
            path = 'fixture.primary/1.0.0'
            files = @('Fixture.Primary.nuspec', 'LICENSE.txt', 'THIRD-PARTY-NOTICES.txt')
            sha512 = 'original-package-hash'
        }
        'Fixture.Transitive/1.0.0' = @{
            type = 'package'
            path = 'fixture.transitive/1.0.0'
            files = @('Fixture.Transitive.nuspec', 'LICENSE.txt', 'THIRD-PARTY-NOTICES.txt')
        }
    }
    $framework = @{
        dependencies = @{ 'Fixture.Primary' = @{ target = 'Package'; version = '[1.0.0, )' } }
    }
    if ($DownloadPack) {
        $framework.downloadDependencies = @(@{ name = 'Fixture.Runtime'; version = '[1.0.0, 1.0.0]' })
    }
    $assets = @{
        libraries = $libraries
        targets = @{ 'net10.0' = $libraries }
        packageFolders = @{ "$root/packages" = @{} }
        project = @{
            restore = @{ projectName = $Name; projectPath = $ProjectPath }
            frameworks = @{ 'net10.0' = $framework }
        }
    }
    $path = Join-Path $root "$Name.assets.json"
    $assets | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $path -Encoding utf8NoBOM
    return $path
}

function Expect-Failure {
    param (
        [scriptblock]$Action,
        [string]$Pattern
    )
    $failed = $false
    try {
        & $Action
    }
    catch {
        Require ($_.Exception.Message -match $Pattern) "Unexpected failure: $_"
        $failed = $true
    }
    Require $failed "Expected failure matching $Pattern."
}

try {
    New-Item -ItemType Directory -Path $root -Force | Out-Null
    Write-FixturePackage 'Fixture.Primary' 'LICENSE.txt'
    Write-FixturePackage 'Fixture.Transitive' 'LICENSE.txt'
    Write-FixturePackage 'Fixture.Runtime' 'LICENSE.txt'
    $product = Write-FixtureAssets 'product' '/repo/src/grate/grate.csproj' $true
    $test = Write-FixtureAssets 'tests' '/repo/unittests/Basic_tests/Basic_tests.csproj'
    $exporter = Join-Path $PSScriptRoot 'Export-DependencyLicenses.ps1'
    & $exporter -AssetsFile @($product, $test) -OutputDirectory "$root/first" -RepositoryRoot $repository
    $inventory = Get-Content -LiteralPath "$root/first/dependency-licenses.json" -Raw | ConvertFrom-Json
    Require ($inventory.Count -eq 3) 'Transitive packages and exact-range runtime downloads must be inventoried.'
    $primary = $inventory | Where-Object id -EQ 'Fixture.Primary'
    Require ($primary.contexts -contains 'product/product/direct') 'Product/direct context missing.'
    Require ($primary.contexts -contains 'test/tests/direct') 'Test/direct context missing.'
    $transitive = $inventory | Where-Object id -EQ 'Fixture.Transitive'
    Require ($transitive.contexts -contains 'product/product/transitive/download') 'Transitive context missing.'
    $notice = Get-Content -LiteralPath "$root/first/THIRD-PARTY-NOTICES.txt" -Raw
    Require ($notice.Contains('Original license of Fixture.Primary. Keep this exact copyright and condition.')) 'Original license text lost.'
    Require ($notice.Contains('Nested third-party notice: must survive redistribution.')) 'Nested notices lost.'
    Require ($notice.Contains('Fixture.Runtime')) 'Runtime pack license missing.'
    Require ($notice.Contains('https://www.nuget.org/packages/Fixture.Primary/1.0.0/License')) 'Exact-version license reference missing.'
    $count++

    & $exporter -AssetsFile @($test, $product) -OutputDirectory "$root/second" -RepositoryRoot $repository
    foreach ($filename in @('THIRD-PARTY-NOTICES.txt', 'dependency-licenses.json')) {
        Require ((Get-FileHash "$root/first/$filename").Hash -ceq (Get-FileHash "$root/second/$filename").Hash) "Non-deterministic $filename."
    }
    $count++

    Remove-Item -LiteralPath "$root/packages/fixture.primary/1.0.0/LICENSE.txt"
    Expect-Failure { & $exporter -AssetsFile $product -OutputDirectory "$root/missing" -RepositoryRoot $repository } 'Required package file is missing'
    $count++

    Write-FixturePackage 'Fixture.Primary' 'MIT' 'expression'
    $assets = Get-Content -LiteralPath $product -Raw | ConvertFrom-Json -AsHashtable
    $assets.libraries['Fixture.Primary/1.0.0'].files = @('Fixture.Primary.nuspec', 'THIRD-PARTY-NOTICES.txt')
    $assets | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $product -Encoding utf8NoBOM
    Expect-Failure { & $exporter -AssetsFile $product -OutputDirectory "$root/expression" -RepositoryRoot $repository } 'Original license text unavailable'
    $count++

    & $exporter -AssetsFile $product -OutputDirectory "$root/audit" -RepositoryRoot $repository -AllowMissingLicenseEvidence
    $audit = Get-Content -LiteralPath "$root/audit/dependency-licenses.json" -Raw | ConvertFrom-Json
    Require (($audit | Where-Object id -EQ 'Fixture.Primary').evidence -ceq 'missing-source') 'Audit must disclose incomplete license evidence.'
    $count++

    Write-FixturePackage 'Fixture.Primary' '../outside.txt'
    Expect-Failure { & $exporter -AssetsFile $product -OutputDirectory "$root/traversal" -RepositoryRoot $repository } 'Package file escapes'
    $count++

    Write-FixturePackage 'Fixture.Primary' 'MIT' 'expression'
    'Original upstream license with its copyright and grant.' | Set-Content -LiteralPath "$root/license.txt" -Encoding utf8NoBOM
    $source = @{
        repositoryCommit = ''
        texts = @(@{ file = 'license.txt'; sha256 = ('0' * 64); url = 'https://example.test/exact-commit/LICENSE' })
    }
    @{ 'Fixture.Primary/1.0.0' = $source } | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath "$root/sources.json" -Encoding utf8NoBOM
    Expect-Failure { & $exporter -AssetsFile $product -OutputDirectory "$root/hash" -RepositoryRoot $repository -SourceDirectory $root } 'cache hash mismatch'
    $count++

    $source.texts[0].sha256 = (Get-FileHash -LiteralPath "$root/license.txt").Hash.ToLowerInvariant()
    @{ 'Fixture.Primary/1.0.0' = $source } | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath "$root/sources.json" -Encoding utf8NoBOM
    & $exporter -AssetsFile $product -OutputDirectory "$root/source" -RepositoryRoot $repository -SourceDirectory $root
    $sourced = Get-Content -LiteralPath "$root/source/THIRD-PARTY-NOTICES.txt" -Raw
    Require ($sourced.Contains('Original upstream license with its copyright and grant.')) 'Pinned original source license lost.'
    $count++

    $nuspec = "$root/packages/fixture.primary/1.0.0/Fixture.Primary.nuspec"
    (Get-Content -LiteralPath $nuspec -Raw) -replace '<license[^>]*>.*?</license>', '<licenseUrl>https://example.test/legacy-license</licenseUrl>' |
        Set-Content -LiteralPath $nuspec -Encoding utf8NoBOM
    Expect-Failure { & $exporter -AssetsFile $product -OutputDirectory "$root/legacy-failure" -RepositoryRoot $repository } 'No declared license'
    & $exporter -AssetsFile $product -OutputDirectory "$root/legacy-audit" -RepositoryRoot $repository -AllowMissingLicenseEvidence
    $legacy = Get-Content -LiteralPath "$root/legacy-audit/dependency-licenses.json" -Raw | ConvertFrom-Json |
        Where-Object id -EQ 'Fixture.Primary'
    Require ($legacy.evidence -ceq 'missing-license-declaration') 'Legacy package needs an explicit unresolved status.'
    Require ($legacy.licenseUrl -ceq 'https://example.test/legacy-license') 'Original legacy license URL lost.'
    Require ([string]::IsNullOrEmpty($legacy.license)) 'Audit must not invent a legacy license grant.'
    $count++
}
finally {
    if (Test-Path -LiteralPath $root) {
        Remove-Item -LiteralPath $root -Recurse -Force
    }
}
Write-Host "PASS: $count dependency license export scenarios."
