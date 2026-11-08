#!/usr/bin/env pwsh
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string] $NeedsJson
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$requiredJobs = @('build-code', 'fast-tests', 'analyze', 'test', 'report', 'packages', 'standalone', 'docker', 'validation-policy', 'pr-validation')
$results = ConvertFrom-Json -InputObject $NeedsJson -AsHashtable
if ($results -isnot [System.Collections.IDictionary]) {
    throw 'CI results must be an object containing every required job.'
}

$unsuccessfulJobs = @()
foreach ($job in $requiredJobs) {
    $result = $results[$job]
    if ($result -isnot [System.Collections.IDictionary] -or !$result.Contains('result')) {
        $unsuccessfulJobs += "${job}: missing result"
    } elseif ($result.result -cne 'success') {
        $unsuccessfulJobs += "${job}: $($result.result)"
    }
}

if ($unsuccessfulJobs.Count -gt 0) {
    throw "CI did not complete successfully: $($unsuccessfulJobs -join '; ')."
}

Write-Host 'PASS: build, tests, security analysis, reports, package checks and PR validation succeeded.'
