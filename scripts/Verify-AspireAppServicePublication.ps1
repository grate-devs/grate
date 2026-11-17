#!/usr/bin/env pwsh
[CmdletBinding()]
param(
    [ValidateSet('Debug', 'Release')]
    [string]$Configuration = 'Release',
    [switch]$NoBuild
)

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true
$repository = Split-Path $PSScriptRoot -Parent
$directory = Join-Path $repository 'examples/aspire/AzureAppService/PublicationChecks'
$project = Join-Path $directory 'PublicationChecks.csproj'
$executable = Join-Path $directory "bin/$Configuration/net10.0/Grate.Aspire.AppService.PublicationChecks.dll"
$workspace = Join-Path ([IO.Path]::GetTempPath()) "grate-app-service-check-$([Guid]::NewGuid().ToString('N'))"
$previousOutput = $env:GRATE_APP_SERVICE_CHECK_OUTPUT

Push-Location ([IO.Path]::GetTempPath())
try {
    if (!$NoBuild) {
        dotnet build $project --configuration $Configuration --nologo
    }
    if (!(Test-Path -LiteralPath $executable -PathType Leaf)) {
        throw "Build the publication checks before using -NoBuild: $executable"
    }
    $null = New-Item -ItemType Directory -Path $workspace
    $env:GRATE_APP_SERVICE_CHECK_OUTPUT = $workspace
    $log = Join-Path $workspace 'publication.log'
    dotnet $executable *> $log
    Get-Content -LiteralPath $log | Where-Object { $_ -match '^PASS:' } | Write-Output
    Remove-Item -LiteralPath $workspace -Recurse -Force
}
catch {
    throw "App Service publication verification failed. Local artifacts and diagnostics: $workspace. $($_.Exception.Message)"
}
finally {
    $env:GRATE_APP_SERVICE_CHECK_OUTPUT = $previousOutput
    Pop-Location
}
