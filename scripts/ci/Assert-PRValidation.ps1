#!/usr/bin/env pwsh
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string] $NeedsJson,
    [Parameter(Mandatory)][string] $JobsJson,
    [Parameter(Mandatory)][ValidateRange(1, [long]::MaxValue)][long] $RunId,
    [Parameter(Mandatory)][ValidateRange(1, [int]::MaxValue)][int] $RunAttempt
)

$ErrorActionPreference = 'Stop'

# This inventory is deliberately independent of the workflow's matrix. Removing a
# lane from YAML must not silently redefine the work required for a green check.
$requiredGroups = @('build-code', 'test', 'packages', 'standalone', 'docker', 'validation-policy')
$requiredJobs = @(
    'Build'
    'NuGet libraries and installed tool'
    'PR validation policy'
    'Run tests (ubuntu-latest, Basic_tests)'
    'Run tests (ubuntu-latest, SqlServer)'
    'Run tests (ubuntu-latest, SqlServerCaseSensitive)'
    'Run tests (ubuntu-latest, PostgreSQL)'
    'Run tests (ubuntu-latest, MariaDB)'
    'Run tests (ubuntu-latest, Sqlite)'
    'Run tests (ubuntu-latest, Oracle)'
    'Run tests (windows-latest, Basic_tests)'
    'Run tests (windows-latest, Sqlite)'
    'Run tests (windows-latest, SqlServer, SqlServer.Basic_tests.*)'
    'Run tests (windows-latest, SqlServerCaseSensitive, SqlServerCaseSensitive.Basic_tests.*)'
    'Run tests (windows-latest, MariaDB, MariaDB.Basic_tests.*)'
    'Run tests (windows-latest, Oracle, Oracle.Basic_tests.*)'
    'CLI win-x64'
    'CLI win-x86'
    'CLI win-arm64'
    'CLI linux-x64'
    'CLI linux-arm64'
    'CLI linux-musl-x64'
    'CLI linux-musl-arm64'
    'CLI osx-x64'
    'CLI osx-arm64'
    'Alpine amd64'
    'Alpine arm64'
)

$needs = ConvertFrom-Json -InputObject $NeedsJson -AsHashtable
$jobs = ConvertFrom-Json -InputObject $JobsJson -AsHashtable -NoEnumerate
if ($needs -isnot [System.Collections.IDictionary]) { throw 'Expected a needs object.' }
if ($jobs -isnot [array]) { throw 'Expected a jobs array.' }

$problems = [System.Collections.Generic.List[string]]::new()
foreach ($group in $requiredGroups) {
    if (!$needs.Contains($group)) {
        $problems.Add("Missing required dependency '$group'.")
    } elseif ($needs[$group] -isnot [System.Collections.IDictionary] -or $needs[$group].result -cne 'success') {
        $problems.Add("Required dependency '$group' did not succeed.")
    }
}

# The caller retrieves every page with filter=all. A partial rerun preserves
# successful jobs from earlier attempts of this same immutable workflow run.
# Select the latest attempt per name, never an older success over a newer failure.
foreach ($job in $jobs) {
    if ($job -isnot [System.Collections.IDictionary] -or [string]$job.run_id -cne [string]$RunId) {
        throw 'Job evidence belongs to a different or missing run ID.'
    }
    if ([string]$job.run_attempt -cnotmatch '^[1-9][0-9]*$' -or [long]$job.run_attempt -gt $RunAttempt) {
        throw 'Job evidence has a missing, invalid or future run attempt.'
    }
}

foreach ($name in $requiredJobs) {
    $matches = @($jobs | Where-Object { $_.name -ceq $name })
    if ($matches.Count -eq 0) {
        $problems.Add("Missing required job '$name'.")
        continue
    }
    $duplicateAttempts = @($matches | Group-Object run_attempt | Where-Object Count -gt 1)
    if ($duplicateAttempts.Count -gt 0) {
        $problems.Add("Duplicate required job '$name' in the same attempt.")
        continue
    }
    $latest = $matches | Sort-Object { [long]$_.run_attempt } -Descending | Select-Object -First 1
    if ($latest.status -cne 'completed' -or $latest.conclusion -cne 'success') {
        $problems.Add("Required job '$name' is '$($latest.status)/$($latest.conclusion)' in attempt $($latest.run_attempt).")
    }

    # A successful upload or job summary cannot stand in for the correctness
    # steps. Only steps applicable to this platform are mandatory; the workflow
    # intentionally skips the other platform's steps within the same job.
    $stepNames = @(switch -CaseSensitive -Wildcard ($name) {
        'Build' { 'Restore dependencies'; 'Build' }
        'PR validation policy' { 'Test aggregate decision policy' }
        'NuGet libraries and installed tool' {
            'Check standalone verification command contract'
            'Verify packages across supported frameworks'
        }
        'Run tests (ubuntu-latest,*' { 'Test on Linux' }
        'Run tests (windows-latest,*' { 'Test on Windows' }
        'CLI *' { 'Verify self-contained runtime and execution' }
        'Alpine *' {
            'Build native image for verification'
            'Verify Alpine globalization, migration and bundled skill'
            'Ensure SQLite client for entrypoint verification'
            'Verify default image entrypoint'
        }
    })
    if ($name -cin @('CLI win-x64', 'CLI win-arm64')) {
        $stepNames += @(
            'Check per-user MSI authoring regressions'
            'Build MSI from verified Windows binary'
            'Check verified Windows MSI metadata'
            'Verify installed MSI, major upgrade and uninstall'
        )
    }
    if ($name -cin @('CLI linux-x64', 'CLI linux-arm64')) {
        $stepNames += @(
            'Build Debian packages from verified Linux binary'
            'Verify Debian installation, package upgrade and purge'
        )
    }
    foreach ($stepName in $stepNames) {
        $steps = @($latest.steps | Where-Object { $_.name -ceq $stepName })
        if ($steps.Count -eq 0) {
            $problems.Add("Missing required step '$stepName' in '$name'.")
        } elseif ($steps.Count -ne 1) {
            $problems.Add("Duplicate required step '$stepName' in '$name'.")
        } elseif ($steps[0].status -cne 'completed' -or $steps[0].conclusion -cne 'success') {
            $problems.Add("Required step '$stepName' in '$name' is '$($steps[0].status)/$($steps[0].conclusion)'.")
        }
    }
}

if ($problems.Count -gt 0) {
    throw "PR validation failed:`n$($problems -join "`n")"
}
Write-Host "PASS: all $($requiredGroups.Count) dependencies and $($requiredJobs.Count) required jobs succeeded for run $RunId, attempt $RunAttempt."
