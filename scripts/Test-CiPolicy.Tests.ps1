#!/usr/bin/env pwsh
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repositoryRoot = Split-Path -Parent $PSScriptRoot
$workflow = Get-Content -LiteralPath "$repositoryRoot/.github/workflows/ci.yml" -Raw
$preflightScript = Get-Content -LiteralPath "$repositoryRoot/scripts/ci/Invoke-Preflight.ps1" -Raw
$aggregate = Join-Path $PSScriptRoot 'Assert-CiResults.ps1'
$requiredJobs = @('build-code', 'fast-tests', 'analyze', 'test', 'report', 'packages', 'standalone', 'docker', 'validation-policy', 'pr-validation')
$expensiveJobs = @('analyze', 'test', 'packages', 'standalone', 'docker')

function Assert-WorkflowPolicy {
    param(
        [string] $Workflow,
        [string] $Preflight = $preflightScript
    )

    # Inspect only this scheduling contract. actionlint checks full YAML and
    # expression syntax; these assertions reject accidental gate bypasses.
    $jobs = @{}
    foreach ($match in [regex]::Matches($Workflow, '(?ms)^  ([a-z][a-z0-9-]*):\r?\n(.*?)(?=^  [a-z][a-z0-9-]*:\r?\n|\z)')) {
        $jobs[$match.Groups[1].Value] = $match.Groups[2].Value
    }

    foreach ($job in $expensiveJobs) {
        if (!$jobs.ContainsKey($job) -or $jobs[$job] -notmatch '(?m)^    needs: \[build-code, fast-tests, validation-policy\]\r?$') {
            throw "Expensive job $job must depend on Build, validation policy and both isolated test lanes."
        }
        if ($jobs[$job] -match '(?m)^    (if|continue-on-error):') {
            throw "Expensive job $job must preserve the default success-only dependency condition."
        }
    }

    foreach ($job in @('build-code', 'fast-tests')) {
        if ($jobs[$job] -notmatch '(?m)^    needs: validation-policy\r?$') {
            throw "$job must depend on build-independent checks."
        }
        if ($jobs[$job] -match '(?m)^    (if|continue-on-error):') {
            throw "$job cannot bypass failed build-independent checks."
        }
    }
    if (!$jobs['validation-policy'].Contains('uses: ./.github/actions/preflight')) {
        throw 'The first job must run the shared build-independent checks.'
    }

    $aggregateJob = $jobs['ci-result']
    $expectedNeeds = '    needs: [' + ($requiredJobs -join ', ') + ']'
    if (!$aggregateJob -or !$aggregateJob.Contains($expectedNeeds) -or $aggregateJob -notmatch '(?m)^    if: always\(\)\r?$') {
        throw 'The CI result must always evaluate every required producer.'
    }
    if (!$aggregateJob.Contains('CI_NEEDS_JSON: ${{ toJSON(needs) }}') -or !$aggregateJob.Contains('./scripts/Assert-CiResults.ps1 -NeedsJson $env:CI_NEEDS_JSON')) {
        throw 'The CI result must validate actual dependency results with the tested gate.'
    }
    if ($jobs['report'] -notmatch '(?m)^     needs: \[fast-tests, test\]\r?$') {
        throw 'The test report must collect both test tiers.'
    }
    if ($jobs['test'] -match 'category: Basic_tests' -or ([regex]::Matches($jobs['fast-tests'], 'category: Basic_tests')).Count -ne 2) {
        throw 'Linux and Windows isolated tests must run once after preflight.'
    }
    if (!$Preflight.Contains('-Path .github/scripts -Filter monitor-test-containers.Tests.ps1') -or $jobs['fast-tests'].Contains('monitor-test-containers.Tests.ps1') -or $jobs['test'].Contains('monitor-test-containers.Tests.ps1')) {
        throw 'Container monitor regressions must run before compiling test projects.'
    }
}

function Assert-Rejected {
    param(
        [scriptblock] $Action,
        [string] $ExpectedMessage
    )

    $rejected = $false
    try {
        & $Action
    } catch {
        if ($_.Exception.Message -notlike "*$ExpectedMessage*") {
            throw
        }
        $rejected = $true
    }
    if (!$rejected) {
        throw "Expected rejection containing '$ExpectedMessage'."
    }
}

Assert-WorkflowPolicy -Workflow $workflow

$successfulResults = @{}
foreach ($job in $requiredJobs) {
    $successfulResults[$job] = @{ result = 'success' }
}
& $aggregate -NeedsJson ($successfulResults | ConvertTo-Json -Depth 3 -Compress)

$rejectionCount = 0
foreach ($job in $requiredJobs) {
    foreach ($state in @('failure', 'cancelled', 'skipped', 'unknown', '')) {
        $results = $successfulResults.Clone()
        $results[$job] = @{ result = $state }
        Assert-Rejected -Action {
            & $aggregate -NeedsJson ($results | ConvertTo-Json -Depth 3 -Compress)
        } -ExpectedMessage "${job}:"
        $rejectionCount++
    }
    foreach ($missingResult in @($null, @{})) {
        $results = $successfulResults.Clone()
        $results[$job] = $missingResult
        Assert-Rejected -Action {
            & $aggregate -NeedsJson ($results | ConvertTo-Json -Depth 3 -Compress)
        } -ExpectedMessage "${job}: missing result"
        $rejectionCount++
    }
    $results = $successfulResults.Clone()
    $results.Remove($job)
    Assert-Rejected -Action {
        & $aggregate -NeedsJson ($results | ConvertTo-Json -Depth 3 -Compress)
    } -ExpectedMessage "${job}: missing result"
    $rejectionCount++
}

Assert-Rejected -Action { & $aggregate -NeedsJson '{}' } -ExpectedMessage 'missing result'
Assert-Rejected -Action { & $aggregate -NeedsJson '[]' } -ExpectedMessage 'must be an object'

# These mutations must be rejected even if every remaining job would be green.
$bypassedDependency = $workflow.Replace('needs: [build-code, fast-tests, validation-policy]', 'needs: [build-code]')
Assert-Rejected -Action { Assert-WorkflowPolicy -Workflow $bypassedDependency } -ExpectedMessage 'must depend'
$bypassedPolicy = $workflow.Replace('needs: [build-code, fast-tests, validation-policy]', 'needs: [build-code, fast-tests]')
Assert-Rejected -Action { Assert-WorkflowPolicy -Workflow $bypassedPolicy } -ExpectedMessage 'must depend'
$skippedAggregate = $workflow.Replace('    if: always()', '    if: success()')
Assert-Rejected -Action { Assert-WorkflowPolicy -Workflow $skippedAggregate } -ExpectedMessage 'must always evaluate'
$missingProducer = $workflow.Replace('needs: [build-code, fast-tests, analyze, test, report, packages, standalone, docker, validation-policy, pr-validation]', 'needs: [build-code, fast-tests, analyze, test, report, packages, standalone, docker, validation-policy]')
Assert-Rejected -Action { Assert-WorkflowPolicy -Workflow $missingProducer } -ExpectedMessage 'must always evaluate'
$missingMonitorTests = $preflightScript.Replace('-Path .github/scripts -Filter monitor-test-containers.Tests.ps1', '-Path scripts -Filter skipped.ps1')
Assert-Rejected -Action { Assert-WorkflowPolicy -Workflow $workflow -Preflight $missingMonitorTests } -ExpectedMessage 'Container monitor regressions must run'
$ungatedBuilds = $workflow.Replace('    needs: validation-policy', '')
Assert-Rejected -Action { Assert-WorkflowPolicy -Workflow $ungatedBuilds } -ExpectedMessage 'must depend on build-independent checks'
$bypassedChecks = $workflow.Replace('uses: ./.github/actions/preflight', 'run: Write-Host skipped')
Assert-Rejected -Action { Assert-WorkflowPolicy -Workflow $bypassedChecks } -ExpectedMessage 'must run the shared'

Write-Host "PASS: staged wiring, all-success aggregate, $rejectionCount per-job rejection cases, empty input and scheduling mutations."
