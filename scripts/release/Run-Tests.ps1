#!/usr/bin/env pwsh
param (
    [string]$Path = $PSScriptRoot,
    [string]$Filter = 'test_*.ps1'
)
$ErrorActionPreference = 'Stop'
$tests = @(Get-ChildItem -LiteralPath $Path -Filter $Filter -File | Sort-Object Name)
if ($tests.Count -eq 0) { throw "No tests matched $Filter in $Path." }
foreach ($test in $tests) {
    Write-Host "Running $($test.Name)"
    & (Join-Path $PSHOME 'pwsh') -NoLogo -NoProfile -File $test.FullName
    if ($LASTEXITCODE -ne 0) { throw "$($test.Name) failed with exit code $LASTEXITCODE." }
}
Write-Host "PASS: $($tests.Count) PowerShell test scripts."
