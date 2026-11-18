#!/usr/bin/env pwsh
$ErrorActionPreference = 'Stop'

$validate = Join-Path $PSScriptRoot 'Assert-CompatibilityValidation.ps1'
$arguments = @{
    RunId = 5555
    RunAttempt = 2
    HeadSha = '1111111111111111111111111111111111111111'
    Tier = 'pr-preview'
    EventName = 'workflow_dispatch'
    Ref = 'refs/heads/ci/942-compatibility-pr957'
}
$needs = @{
    preflight = @{ result = 'success' }
    'set-version-number' = @{ result = 'success' }
    'build-standalone' = @{ result = 'success' }
    'build-tests' = @{ result = 'success' }
    'cli-database-integration-tests' = @{ result = 'success' }
}
$buildNames = @(
    'Build-independent checks', 'Set version number', 'Build tests (linux-x64)',
    'Build All cli', 'Build SQLite cli', 'Build SQLServer cli',
    'Build MariaDB cli', 'Build PostgreSQL cli', 'Build Oracle cli'
)
$previewDatabases = @('SqlServer 2025', 'SqlServer case-sensitive 2022', 'PostgreSQL 18', 'MariaDB 12', 'Sqlite', 'Oracle Free latest')
$fullDatabases = $previewDatabases + @(
    'SqlServer 2022', 'SqlServer 2019', 'SqlServer 2017',
    'PostgreSQL 17', 'PostgreSQL 16', 'PostgreSQL 15', 'PostgreSQL 14', 'PostgreSQL 13', 'PostgreSQL 12',
    'MariaDB 13', 'MariaDB 11', 'MariaDB 10.4', 'MariaDB 10.10', 'Oracle XE latest', 'Oracle XE 18'
)

function New-SucceededJob([string] $Name) {
    @{
        name = $Name
        run_id = $arguments.RunId
        run_attempt = 1
        head_sha = $arguments.HeadSha
        status = 'completed'
        conclusion = 'success'
        steps = @(@{ name = 'Docker Test CmdLine'; status = 'completed'; conclusion = 'success' })
    }
}

function New-Jobs([string[]] $Databases) {
    foreach ($name in $buildNames) {
        New-SucceededJob $name
    }
    foreach ($database in $Databases) {
        New-SucceededJob "All CLI / $database"
        New-SucceededJob "Slim CLI / $database"
    }
}

function Assert-Rejected([string] $Message, [scriptblock] $Action) {
    try {
        & $Action
    } catch {
        if (!$_.Exception.Message.Contains($Message)) { throw }
        return
    }
    throw "Expected validation to reject '$Message'."
}

$jobs = @(New-Jobs $previewDatabases)
$queuedReport = New-SucceededJob 'Report'
$queuedReport.status = 'queued'
$queuedReport.conclusion = $null
$disabledMacBuild = New-SucceededJob 'Build tests'
$disabledMacBuild.conclusion = 'skipped'
$jobs += @($queuedReport, $disabledMacBuild)
& $validate @arguments -Needs $needs -Jobs $jobs

$full = $arguments.Clone()
$full.Tier = 'full'
& $validate @full -Needs $needs -Jobs @(New-Jobs $fullDatabases)
Assert-Rejected "Missing required job" {
    & $validate @full -Needs $needs -Jobs $jobs
}
Assert-Rejected "Unexpected compatibility job" {
    & $validate @arguments -Needs $needs -Jobs @(New-Jobs $fullDatabases)
}
Assert-Rejected "Missing required job 'Build Oracle cli'." {
    $missingBuild = @($jobs | Where-Object { $_.name -cne 'Build Oracle cli' })
    & $validate @arguments -Needs $needs -Jobs $missingBuild
}
Assert-Rejected "Missing required job 'Slim CLI / Oracle Free latest'." {
    $missingLane = @($jobs | Where-Object { $_.name -cne 'Slim CLI / Oracle Free latest' })
    & $validate @arguments -Needs $needs -Jobs $missingLane
}

foreach ($result in @('failure', 'skipped', 'cancelled')) {
    $failedNeeds = $needs.Clone()
    $failedNeeds['cli-database-integration-tests'] = @{ result = $result }
    Assert-Rejected "Required dependency 'cli-database-integration-tests' did not succeed." {
        & $validate @arguments -Needs $failedNeeds -Jobs $jobs
    }
}
$missingNeeds = $needs.Clone()
$missingNeeds.Remove('cli-database-integration-tests')
Assert-Rejected "Required dependency 'cli-database-integration-tests' did not succeed." {
    & $validate @arguments -Needs $missingNeeds -Jobs $jobs
}

$lane = 'Slim CLI / Oracle Free latest'
$retriedLane = New-SucceededJob $lane
$retriedLane.run_attempt = 2
$retriedJobs = $jobs + $retriedLane
& $validate @arguments -Needs $needs -Jobs $retriedJobs
foreach ($result in @('failure', 'skipped', 'cancelled')) {
    $retriedLane.conclusion = $result
    Assert-Rejected "Required job '$lane' is 'completed/$result' in attempt 2." {
        & $validate @arguments -Needs $needs -Jobs $retriedJobs
    }
}
$retriedLane.conclusion = 'success'
$retriedLane.steps[0].conclusion = 'skipped'
Assert-Rejected "Expected one successful 'Docker Test CmdLine' step in '$lane' in attempt 2." {
    & $validate @arguments -Needs $needs -Jobs $retriedJobs
}
$retriedLane.steps = @()
Assert-Rejected "Expected one successful 'Docker Test CmdLine' step in '$lane' in attempt 2." {
    & $validate @arguments -Needs $needs -Jobs $retriedJobs
}
$retriedLane.steps = @((New-SucceededJob $lane).steps[0])
Assert-Rejected "Duplicate required job '$lane' in the same attempt." {
    & $validate @arguments -Needs $needs -Jobs ($retriedJobs + $retriedLane)
}
$retriedLane.run_attempt = 3
Assert-Rejected 'Job evidence has a missing, invalid or future run attempt.' {
    & $validate @arguments -Needs $needs -Jobs $retriedJobs
}
$retriedLane.run_attempt = 2
$retriedLane.run_id = 5000
Assert-Rejected 'Job evidence belongs to a different or missing run ID or commit.' {
    & $validate @arguments -Needs $needs -Jobs $retriedJobs
}
$retriedLane.run_id = $arguments.RunId
$retriedLane.head_sha = '2222222222222222222222222222222222222222'
Assert-Rejected 'Job evidence belongs to a different or missing run ID or commit.' {
    & $validate @arguments -Needs $needs -Jobs $retriedJobs
}

Write-Host 'PASS: compatibility evidence for both tiers, report independence, and rejection of absent or invalid results.'
