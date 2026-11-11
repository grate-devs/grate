#!/usr/bin/env pwsh
[CmdletBinding()]
param(
    [ValidateSet('postgresql', 'sqlite', 'sqlserver')]
    [string]$Provider = 'postgresql',
    [ValidateSet('all', 'success', 'retained', 'sql-failure', 'credentials-failure', 'readiness', 'interruption')]
    [string]$Scenario = 'all',
    [ValidateSet('Debug', 'Release')]
    [string]$Configuration = 'Release',
    [switch]$NoBuild
)

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true
$providerDirectory = switch ($Provider) {
    'sqlite' { 'Sqlite/' }
    'sqlserver' { 'SqlServer/' }
    default { '' }
}
$project = Join-Path $PSScriptRoot "${providerDirectory}Smoke/Smoke.csproj"
$executable = Join-Path $PSScriptRoot "${providerDirectory}Smoke/bin/$Configuration/net10.0/Smoke.dll"
$logPath = Join-Path ([System.IO.Path]::GetTempPath()) "grate-aspire-smoke-$([guid]::NewGuid().ToString('N')).log"

# This example targets .NET 10 independently of grate's .NET 11 source-build SDK.
# Launch outside the checkout so SDK selection is deliberate on SDK-10 machines.
Push-Location ([System.IO.Path]::GetTempPath())
try {
    if (!$NoBuild) {
        & dotnet build $project --configuration $Configuration --nologo
    }
    if (!(Test-Path -LiteralPath $executable)) {
        throw "Build the smoke project before using -NoBuild: $executable"
    }

    & dotnet $executable $Scenario *> $logPath
    Get-Content -LiteralPath $logPath | Where-Object { $_ -match '^PASS:' } | Write-Output
}
catch {
    throw "Aspire smoke verification failed. Local diagnostics: $logPath. $($_.Exception.Message)"
}
finally {
    Pop-Location
}
