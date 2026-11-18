#!/usr/bin/env pwsh
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string] $NeedsJson,

    [Parameter(Mandatory)]
    [ValidateSet('baseline', 'early')]
    [string] $CliScheduling
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$requiredJobs = @('build-code', 'fast-tests-linux', 'fast-tests-windows', 'analyze', 'test', 'cli-distributions', 'cli-distributions-early', 'packages', 'standalone', 'docker', 'validation-policy', 'pr-validation')
$inactiveCliJob = if ($CliScheduling -eq 'early') {
    'cli-distributions'
} else {
    'cli-distributions-early'
}
$results = ConvertFrom-Json -InputObject $NeedsJson -AsHashtable
if ($results -isnot [System.Collections.IDictionary]) {
    throw 'CI results must be an object containing every required job.'
}

$unsuccessfulJobs = @()
foreach ($job in $requiredJobs) {
    $expected = if ($job -ceq $inactiveCliJob) { 'skipped' } else { 'success' }
    $result = $results[$job]
    if ($result -isnot [System.Collections.IDictionary] -or !$result.Contains('result')) {
        $unsuccessfulJobs += "${job}: missing result"
    } elseif ($result.result -cne $expected) {
        $unsuccessfulJobs += "${job}: $($result.result) (expected $expected)"
    }
}

if ($unsuccessfulJobs.Count -gt 0) {
    throw "CI did not complete successfully: $($unsuccessfulJobs -join '; ')."
}

Write-Host 'PASS: build, tests, security analysis, package checks and PR validation succeeded.'
