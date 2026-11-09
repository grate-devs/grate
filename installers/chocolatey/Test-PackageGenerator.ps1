#!/usr/bin/env pwsh
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true
$root = Join-Path ([IO.Path]::GetTempPath()) ('grate-chocolatey-test-' + [Guid]::NewGuid().ToString('N'))
$version = '2.3.4-rc.1'
$expected = @('grate', 'grate-sqlite', 'grate-sqlserver', 'grate-mariadb', 'grate-postgresql', 'grate-oracle')
$products = @{
    'grate' = 'grate database migration'
    'grate-sqlite' = 'grate (SQLite)'
    'grate-sqlserver' = 'grate (SQLServer)'
    'grate-mariadb' = 'grate (MariaDB)'
    'grate-postgresql' = 'grate (PostgreSQL)'
    'grate-oracle' = 'grate (Oracle)'
}
$savedInstall = $env:ChocolateyInstall
$fixture = @{ PackFailure = $false }

function New-PeFixture {
    param(
        [string]$Path,
        [string]$ProductName,
        [string]$ProductVersion
    )

    # PowerShell ships Roslyn. Explicit core references avoid requiring a .NET
    # SDK/reference pack just to emit synthetic PE version resources offline.
    [Reflection.Assembly]::LoadFrom((Join-Path $PSHOME 'Microsoft.CodeAnalysis.dll')) | Out-Null
    [Reflection.Assembly]::LoadFrom((Join-Path $PSHOME 'Microsoft.CodeAnalysis.CSharp.dll')) | Out-Null
    $source = @"
using System.Reflection;
[assembly: AssemblyProduct("$ProductName")]
[assembly: AssemblyInformationalVersion("$ProductVersion")]
public class PayloadFixture { }
"@
    $syntax = [Microsoft.CodeAnalysis.CSharp.CSharpSyntaxTree]::ParseText($source)
    $reference = [Microsoft.CodeAnalysis.MetadataReference]::CreateFromFile([object].Assembly.Location)
    $options = [Microsoft.CodeAnalysis.CSharp.CSharpCompilationOptions]::new([Microsoft.CodeAnalysis.OutputKind]::DynamicallyLinkedLibrary)
    $compilation = [Microsoft.CodeAnalysis.CSharp.CSharpCompilation]::Create('fixture').WithOptions($options).AddReferences($reference).AddSyntaxTrees($syntax)
    $resources = $compilation.CreateDefaultWin32Resources($true, $false, $null, $null)
    $stream = [IO.File]::Create($Path)
    try {
        $result = $compilation.Emit($stream, $null, $null, $resources)
        if (!$result.Success) {
            throw ($result.Diagnostics -join "`n")
        }
    } finally {
        $stream.Dispose()
        $resources.Dispose()
    }
}

function Assert-Equal {
    param($Expected, $Actual)

    if ($Expected -cne $Actual) {
        throw "Expected '$Expected', observed '$Actual'."
    }
}

function Assert-Rejected {
    param([scriptblock]$Action)

    $rejected = $false
    try {
        & $Action
    } catch {
        $rejected = $true
    }
    if (!$rejected) {
        throw 'Expected conflicting or invalid package input to fail.'
    }
}

function choco {
    $arguments = @($args)
    if ($fixture.PackFailure) {
        $global:LASTEXITCODE = 17
        return
    }
    Assert-Equal 'pack' $arguments[0]
    $specification = @($arguments | Where-Object { $_.EndsWith('.nuspec') })[0]
    $output = @($arguments | Where-Object { $_.StartsWith('--outputdirectory=') })[0].Substring(18)
    [xml]$metadata = Get-Content -LiteralPath $specification -Raw
    $id = $metadata.package.metadata.id
    Assert-Equal $version $metadata.package.metadata.version
    $package = [IO.Compression.ZipFile]::Open("$output/$id.$version.nupkg", [IO.Compression.ZipArchiveMode]::Create)
    try {
        [IO.Compression.ZipFileExtensions]::CreateEntryFromFile($package, $specification, "$id.nuspec") | Out-Null
        $tools = Join-Path (Split-Path $specification) 'tools'
        foreach ($file in (Get-ChildItem -LiteralPath $tools -File)) {
            [IO.Compression.ZipFileExtensions]::CreateEntryFromFile($package, $file.FullName, "tools/$($file.Name)") | Out-Null
        }
    } finally {
        $package.Dispose()
    }
    $global:LASTEXITCODE = 0
}

try {
    New-Item -ItemType Directory -Path "$root/archives", "$root/packages" -Force | Out-Null
    foreach ($id in $expected) {
        $payload = Join-Path $root "$id.exe"
        New-PeFixture -Path $payload -ProductName $products[$id] -ProductVersion "$version+fixture"
        $archive = [IO.Compression.ZipFile]::Open("$root/archives/$id-win-x64-self-contained-$version.zip", [IO.Compression.ZipArchiveMode]::Create)
        try {
            [IO.Compression.ZipFileExtensions]::CreateEntryFromFile($archive, $payload, 'grate.exe') | Out-Null
        } finally {
            $archive.Dispose()
        }
    }
    & "$PSScriptRoot/Create-Package.ps1" -version $version -ArtifactDirectory "$root/archives" -AllDistributions -OutputDirectory "$root/packages"
    Assert-Equal 6 @(Get-ChildItem -LiteralPath "$root/packages" -Filter '*.nupkg').Count
    foreach ($id in $expected) {
        $inspection = "$root/inspect/$id"
        [IO.Compression.ZipFile]::ExtractToDirectory("$root/packages/$id.$version.nupkg", $inspection)
        [xml]$metadata = Get-Content -LiteralPath "$inspection/$id.nuspec" -Raw
        Assert-Equal $id $metadata.package.metadata.id
        Assert-Equal $version $metadata.package.metadata.version
        $hash = (Get-FileHash -LiteralPath "$root/$id.exe").Hash
        Assert-Equal $hash (Get-FileHash -LiteralPath "$inspection/tools/grate.exe").Hash
        $verification = Get-Content -LiteralPath "$inspection/tools/VERIFICATION.txt" -Raw
        if (!$verification.Contains($hash) -or !$verification.Contains("$id-win-x64-self-contained-$version.zip") -or
            !(Test-Path -LiteralPath "$inspection/tools/LICENSE.txt")) {
            throw "Missing source/hash/license evidence for $id."
        }
    }
    $env:ChocolateyInstall = "$root/chocolatey"
    $conflicts = 0
    foreach ($current in $expected) {
        foreach ($installed in $expected) {
            $installedTools = "$env:ChocolateyInstall/lib/$installed/tools"
            New-Item -ItemType Directory -Path $installedTools -Force | Out-Null
            Set-Content -LiteralPath "$installedTools/grate.exe" -Value 'installed payload'
            $script = "$root/inspect/$current/tools/chocolateyInstall.ps1"
            if ($current -ceq $installed) {
                & $script
            } else {
                Assert-Rejected { & $script }
                Assert-Equal 'installed payload' (Get-Content -LiteralPath "$installedTools/grate.exe")
                $conflicts++
            }
            Remove-Item -LiteralPath "$env:ChocolateyInstall/lib/$installed" -Recurse -Force
        }
    }
    & "$PSScriptRoot/Create-Package.ps1" -grateExe "$root/grate.exe" -version $version -OutputDirectory "$root/default"
    if (!(Test-Path -LiteralPath "$root/default/grate.$version.nupkg")) {
        throw 'Default package identity changed.'
    }
    & "$PSScriptRoot/Create-Package.ps1" -grateExe "$root/grate-oracle.exe" -version $version -Distribution Oracle -ReleaseTag "v$version" -OutputDirectory "$root/prefixed"
    [IO.Compression.ZipFile]::ExtractToDirectory("$root/prefixed/grate-oracle.$version.nupkg", "$root/prefixed-inspect")
    if (!(Get-Content -LiteralPath "$root/prefixed-inspect/tools/VERIFICATION.txt" -Raw).Contains("/download/v$version/")) {
        throw 'The verification URL did not retain the actual v-prefixed release tag.'
    }
    Assert-Rejected {
        & "$PSScriptRoot/Create-Package.ps1" -grateExe "$root/grate.exe" -version $version -Distribution Oracle -OutputDirectory "$root/wrong-profile"
    }
    New-PeFixture -Path "$root/wrong-version.exe" -ProductName 'grate (Oracle)' -ProductVersion '2.3.4+fixture'
    Assert-Rejected {
        & "$PSScriptRoot/Create-Package.ps1" -grateExe "$root/wrong-version.exe" -version $version -Distribution Oracle -OutputDirectory "$root/wrong-version"
    }
    Assert-Rejected {
        & "$PSScriptRoot/Create-Package.ps1" -grateExe "$root/grate.exe" -version $version -ReleaseTag 'v2.3.5' -OutputDirectory "$root/wrong-tag"
    }
    $fixture.PackFailure = $true
    Assert-Rejected {
        & "$PSScriptRoot/Create-Package.ps1" -grateExe "$root/grate.exe" -version $version -OutputDirectory "$root/failed"
    }
    Assert-Rejected {
        & "$PSScriptRoot/Create-Package.ps1" -grateExe "$root/grate.exe" -version '2.3.4+metadata' -OutputDirectory "$root/invalid"
    }
    Write-Host "PASS: six Chocolatey identities/payloads/provenance, $conflicts conflict pairs, same-package upgrades, default All API and packaging failure."
} finally {
    $env:ChocolateyInstall = $savedInstall
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
}
