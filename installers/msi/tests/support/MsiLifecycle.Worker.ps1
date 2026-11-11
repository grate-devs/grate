#!/usr/bin/env pwsh
param(
    [string]$Settings,
    [string]$Script
)

$ErrorActionPreference = 'Stop'
$parameters = Get-Content -LiteralPath $Settings -Raw | ConvertFrom-Json -AsHashtable
try {
    & $Script @parameters
    $succeeded = $?
    if (!$succeeded) {
        $nativeExit = Get-Variable -Name LASTEXITCODE -ValueOnly -ErrorAction SilentlyContinue
        if ($nativeExit -is [int] -and $nativeExit -ne 0) {
            exit $nativeExit
        }
        exit 1
    }
} catch {
    [Console]::Error.WriteLine(($_ | Out-String))
    exit 1
}
