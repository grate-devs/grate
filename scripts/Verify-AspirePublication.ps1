#!/usr/bin/env pwsh
# Publish native ACA templates and execute SQL from the derived migration image, offline.
[CmdletBinding()]
param(
    [ValidateSet('Debug', 'Release')]
    [string]$Configuration = 'Release',
    [switch]$NoBuild
)

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true
$repository = Split-Path $PSScriptRoot -Parent
$directory = Join-Path $repository 'examples/aspire/AzureContainerApps/PublicationChecks'
$project = Join-Path $directory 'PublicationChecks.csproj'
$executable = Join-Path $directory "bin/$Configuration/net10.0/PublicationChecks.dll"
$workspace = Join-Path ([IO.Path]::GetTempPath()) "grate-aspire-publication-$([Guid]::NewGuid().ToString('N'))"
$log = "$workspace.log"
$previousOutput = $env:GRATE_ACA_CHECK_OUTPUT

Push-Location ([IO.Path]::GetTempPath())
try {
    if (!$NoBuild) {
        dotnet build $project --configuration $Configuration --nologo
    }
    if (!(Test-Path -LiteralPath $executable)) {
        throw "Build the publication checks before using -NoBuild: $executable"
    }
    $env:GRATE_ACA_CHECK_OUTPUT = $workspace
    dotnet $executable *> $log
    Get-Content -LiteralPath $log | Where-Object { $_ -match '^PASS:' } | Write-Output
    Remove-Item -LiteralPath $workspace -Recurse -Force
}
catch {
    throw "Offline Aspire publication failed. Local artifacts: $workspace. Diagnostics: $log. $($_.Exception.Message)"
}
finally {
    $env:GRATE_ACA_CHECK_OUTPUT = $previousOutput
    Pop-Location
}
