#!/usr/bin/env pwsh
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string] $NeedsJson,

    [Parameter(Mandatory)]
    [ValidateSet('pull_request', 'workflow_dispatch')]
    [string] $EventName
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$requiredJobs = @('build-code', 'fast-tests', 'analyze', 'test', 'cli-distributions', 'report', 'packages', 'standalone', 'docker', 'validation-policy', 'pr-validation', 'compatibility')
$results = ConvertFrom-Json -InputObject $NeedsJson -AsHashtable
if ($results -isnot [System.Collections.IDictionary]) {
    throw 'CI results must be an object containing every required job.'
}

$unsuccessfulJobs = @()
foreach ($job in $requiredJobs) {
    $result = $results[$job]
    $expectedResult = 'success'
    if ($job -ceq 'compatibility' -and $EventName -ceq 'workflow_dispatch') {
        $expectedResult = 'skipped'
    }
    if ($result -isnot [System.Collections.IDictionary] -or !$result.Contains('result')) {
        $unsuccessfulJobs += "${job}: missing result"
    } elseif ($result.result -cne $expectedResult) {
        $unsuccessfulJobs += "${job}: $($result.result)"
    }
}

if ($unsuccessfulJobs.Count -gt 0) {
    throw "CI did not complete successfully: $($unsuccessfulJobs -join '; ')."
}

Write-Host 'PASS: build, tests, security analysis, reports, package checks and PR validation succeeded.'
