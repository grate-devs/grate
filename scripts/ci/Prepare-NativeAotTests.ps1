#!/usr/bin/env pwsh
param(
    [Parameter(Mandatory)]
    [ValidateSet('Sqlite', 'SqlServer', 'SqlServerCaseSensitive', 'MariaDB', 'PostgreSQL', 'Oracle')]
    [string]$Database,
    [Parameter(Mandatory)]
    [string]$OutputDirectory
)

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true
. "$PSScriptRoot/Distribution.TestPayload.ps1"

$output = [IO.Path]::GetFullPath($OutputDirectory)
if (Test-Path -LiteralPath $output) {
    throw 'Use a fresh output directory to prepare NativeAOT tests.'
}
$repository = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$build = [IO.Directory]::CreateTempSubdirectory('grate-nativeaot-tests-').FullName
Push-Location $repository
try {
    $frameworks = @((dotnet msbuild src/grate/grate.csproj -nologo -getProperty:TargetFrameworks).Trim() -split ';')
    $framework = $frameworks[-1]
    $run = Get-NativeAotTestRunIdentity -Database $Database -Framework $framework -RuntimeIdentifier 'linux-x64'
    Build-DistributionTests -Database $Database -Framework $framework -OutputDirectory $build
    $buildOutput = Get-DistributionTestOutputDirectory -Database $Database -Framework $framework -OutputDirectory $build
    New-Item -ItemType Directory -Path $output | Out-Null
    Copy-Item -LiteralPath $buildOutput -Destination (Join-Path $output 'payload') -Recurse -Force
    Write-NativeAotTestPayloadManifest -Directory $output -Run $run
    Write-Host "Prepared the full Release $framework CommandLine.$Database test payload."
} finally {
    Pop-Location
    Remove-Item -LiteralPath $build -Recurse -Force
}
