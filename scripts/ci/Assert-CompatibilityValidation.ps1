#!/usr/bin/env pwsh
[CmdletBinding()]
param(
    [Parameter(Mandatory)][System.Collections.IDictionary] $Needs,
    [Parameter(Mandatory)][AllowEmptyCollection()][object[]] $Jobs,
    [Parameter(Mandatory)][ValidateRange(1, [long]::MaxValue)][long] $RunId,
    [Parameter(Mandatory)][ValidateRange(1, [int]::MaxValue)][int] $RunAttempt,
    [Parameter(Mandatory)][ValidatePattern('^[0-9a-f]{40}$')][string] $HeadSha,
    [Parameter(Mandatory)][ValidateSet('full', 'pr-preview')][string] $Tier,
    [Parameter(Mandatory)][string] $EventName,
    [Parameter(Mandatory)][string] $Ref
)

$ErrorActionPreference = 'Stop'

$requiredGroups = @('preflight', 'set-version-number', 'build-standalone', 'build-tests', 'cli-database-integration-tests')
foreach ($group in $requiredGroups) {
    if (!$Needs.Contains($group) -or $Needs[$group].result -cne 'success') {
        throw "Required dependency '$group' did not succeed."
    }
}

# Preflight independently pins the selected database names and both variants.
$databases = @(& "$PSScriptRoot/Get-CompatibilityDatabases.ps1" -Tier $Tier -EventName $EventName -Ref $Ref)
$testNames = @(
    foreach ($database in $databases) {
        "All CLI / $($database.name)"
        "Slim CLI / $($database.name)"
    }
)
$buildNames = @('Build-independent checks', 'Set version number', 'Build tests (linux-x64)')
$buildNames += @('All', 'SQLite', 'SQLServer', 'MariaDB', 'PostgreSQL', 'Oracle') | ForEach-Object { "Build $_ cli" }
$requiredNames = $buildNames + $testNames

foreach ($job in $Jobs) {
    if ([string]$job.run_id -cne [string]$RunId -or $job.head_sha -cne $HeadSha) {
        throw 'Job evidence belongs to a different or missing run ID or commit.'
    }
    if ([string]$job.run_attempt -cnotmatch '^[1-9][0-9]*$' -or [long]$job.run_attempt -gt $RunAttempt) {
        throw 'Job evidence has a missing, invalid or future run attempt.'
    }
    if ($job.name -isnot [string] -or [string]::IsNullOrWhiteSpace($job.name)) {
        throw 'Job evidence has a missing or invalid job name.'
    }
    if ($job.name -match '^(All|Slim) CLI / ' -and $job.name -cnotin $testNames) {
        throw "Unexpected compatibility job '$($job.name)'."
    }
}

foreach ($name in $requiredNames) {
    $matching = @($Jobs | Where-Object { $_.name -ceq $name })
    if ($matching.Count -eq 0) {
        throw "Missing required job '$name'."
    }
    if (@($matching | Group-Object { [int]$_.run_attempt } | Where-Object Count -gt 1).Count -gt 0) {
        throw "Duplicate required job '$name' in the same attempt."
    }

    # A failed-job rerun can reuse earlier successful jobs from this run.
    $latest = $matching | Sort-Object { [int]$_.run_attempt } -Descending | Select-Object -First 1
    if ($latest.status -cne 'completed' -or $latest.conclusion -cne 'success') {
        throw "Required job '$name' is '$($latest.status)/$($latest.conclusion)' in attempt $($latest.run_attempt)."
    }
    if ($name -cin $testNames) {
        $step = @($latest.steps | Where-Object { $_.name -ceq 'Docker Test CmdLine' })
        if ($step.Count -ne 1 -or $step[0].status -cne 'completed' -or $step[0].conclusion -cne 'success') {
            throw "Expected one successful 'Docker Test CmdLine' step in '$name' in attempt $($latest.run_attempt)."
        }
    }
}

Write-Host "PASS: $($testNames.Count) $Tier compatibility lanes and all prerequisite jobs passed for run $RunId, attempt $RunAttempt."
