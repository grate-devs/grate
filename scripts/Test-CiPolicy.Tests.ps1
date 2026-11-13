#!/usr/bin/env pwsh
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repositoryRoot = Split-Path -Parent $PSScriptRoot
. "$PSScriptRoot/release/workflow_test_helpers.ps1"
$phases = (Read-Workflow 'ci.yml').jobs
$workflow = Get-Content -LiteralPath "$repositoryRoot/.github/workflows/ci.yml" -Raw
$preflightScript = Get-Content -LiteralPath "$repositoryRoot/scripts/ci/Invoke-Preflight.ps1" -Raw
$aggregate = Join-Path $PSScriptRoot 'Assert-CiResults.ps1'
$requiredJobs = @('build-code', 'fast-tests', 'analyze', 'test', 'cli-distribution-build', 'cli-distributions', 'report', 'packages', 'standalone', 'docker', 'validation-policy', 'pr-validation')
$expensiveJobs = @('analyze', 'test', 'cli-distribution-build', 'cli-distributions', 'packages', 'standalone', 'docker')
$analysisCondition = "`${{ !cancelled() && (github.event_name == 'push' || github.event_name == 'schedule' || ((github.event_name == 'pull_request' || github.event_name == 'workflow_dispatch') && needs.build-code.result == 'success' && needs.fast-tests.result == 'success' && needs.validation-policy.result == 'success')) }}"
$aggregateCondition = "    if: always() && (github.event_name == 'pull_request' || github.event_name == 'workflow_dispatch')"

function Assert-CiPhaseCoverage {
    param(
        [hashtable]$Phases
    )

    $expectedDatabaseLanes = @(
        'ubuntu-latest/SqlServer/'
        'ubuntu-latest/SqlServerCaseSensitive/'
        'ubuntu-latest/PostgreSQL/'
        'ubuntu-latest/MariaDB/'
        'ubuntu-latest/Sqlite/'
        'ubuntu-latest/Oracle/'
        'windows-latest/Sqlite/'
        'windows-latest/SqlServer/SqlServer.Basic_tests.*'
        'windows-latest/SqlServerCaseSensitive/SqlServerCaseSensitive.Basic_tests.*'
        'windows-latest/MariaDB/MariaDB.Basic_tests.*'
        'windows-latest/Oracle/Oracle.Basic_tests.*'
    )
    $actualDatabaseLanes = @($Phases.test.strategy.matrix.include | ForEach-Object {
        "$($_.os)/$($_.category)/$($_.test_filter)"
    })
    if ((@($expectedDatabaseLanes | Sort-Object) -join ',') -cne (@($actualDatabaseLanes | Sort-Object) -join ',')) {
        throw 'Preserve all eleven library database/platform/filter lanes.'
    }
    $expectedFlags = @{
        'Test on Linux' = @{
            GRATE_SQLSERVER_SCOPED_POOLING = '${{ matrix.category == ''SqlServer'' && ''true'' || ''false'' }}'
            GRATE_ORACLE_SCOPED_POOLING = '${{ matrix.category == ''Oracle'' && ''true'' || ''false'' }}'
            GRATE_REPRODUCIBLE_TABLE_CASINGS = '${{ (matrix.category == ''SqlServer'' || matrix.category == ''Oracle'') && ''true'' || ''false'' }}'
        }
        'Test on Windows' = @{
            GRATE_SQLSERVER_SCOPED_POOLING = '${{ matrix.category == ''SqlServer'' && ''true'' || ''false'' }}'
            GRATE_REPRODUCIBLE_TABLE_CASINGS = '${{ matrix.category == ''SqlServer'' && ''true'' || ''false'' }}'
        }
    }
    $flagNames = @('GRATE_SQLSERVER_SCOPED_POOLING', 'GRATE_ORACLE_SCOPED_POOLING', 'GRATE_REPRODUCIBLE_TABLE_CASINGS')
    $flagFailure = 'Preserve provider-specific pooling and casing flags in their test steps without job-level overrides.'
    if ($Phases.test.ContainsKey('env')) {
        foreach ($name in $flagNames) {
            if ($Phases.test.env.ContainsKey($name)) {
                throw $flagFailure
            }
        }
    }
    foreach ($stepName in $expectedFlags.Keys) {
        $steps = @($Phases.test.steps | Where-Object { $_['name'] -ceq $stepName })
        if ($steps.Count -ne 1 -or !$steps[0].ContainsKey('env')) {
            throw $flagFailure
        }
        foreach ($name in $expectedFlags[$stepName].Keys) {
            if (!$steps[0].env.ContainsKey($name) -or $steps[0].env[$name] -cne $expectedFlags[$stepName][$name]) {
                throw $flagFailure
            }
        }
    }
    foreach ($step in $Phases.test.steps) {
        if (!$step.ContainsKey('env')) {
            continue
        }
        foreach ($name in $flagNames) {
            if ($step.env.ContainsKey($name) -and (!$step.ContainsKey('name') -or
                    !$expectedFlags.ContainsKey($step.name) -or !$expectedFlags[$step.name].ContainsKey($name))) {
                throw $flagFailure
            }
        }
    }
    foreach ($id in @('build-code', 'fast-tests', 'analyze', 'test', 'packages')) {
        $setup = Get-ActionStep $Phases[$id] 'actions/setup-dotnet'
        $versions = @($setup.with.'dotnet-version' -split '\r?\n' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
        if ($setup.with.'global-json-file' -cne 'global.json' -or
            ($versions -join ',') -cne '8.0.x,9.0.x,10.0.x') {
            throw "Preserve the pinned SDK and earlier runtime setup in $id."
        }
    }
    foreach ($id in @('fast-tests', 'test')) {
        $upload = Get-ActionStep $Phases[$id] 'actions/upload-artifact'
        if ($upload.if -cne 'always()' -or $upload.with.'retention-days' -ne 1 -or
            $upload.with.name -cne '${{ matrix.os }} ${{ matrix.category }} XML test results') {
            throw 'Retain both test tiers under their existing artifact names on failure.'
        }
    }
    $distributionReports = $Phases['cli-distributions'].steps | Where-Object { $_['name'] -ceq 'Upload distribution test results' }
    if ($distributionReports.if -cne 'always()' -or $distributionReports.with.'retention-days' -ne 3 -or
        $distributionReports.with.name -cne '${{ matrix.distribution }} ${{ matrix.database }} CLI XML test results') {
        throw 'Retain per-provider CLI test artifacts on failure with stable identities.'
    }
    $standaloneUpload = Get-ActionStep $Phases.standalone 'actions/upload-artifact'
    $dockerUpload = Get-ActionStep $Phases.docker 'actions/upload-artifact'
    if ($standaloneUpload.if -cne 'always()' -or $dockerUpload.if -cne 'always()' -or
        $standaloneUpload.with.'retention-days' -ne 3 -or $dockerUpload.with.'retention-days' -ne 3) {
        throw 'Keep native CLI/installer and Docker diagnostics on failure.'
    }
    $lifecycle = $Phases.standalone.steps | Where-Object { $_['name'] -ceq 'Verify installed MSI, major upgrade and uninstall' }
    if (!$lifecycle.run.Contains('-TimeoutSeconds 360') -or
        !$lifecycle.ContainsKey('timeout-minutes') -or $lifecycle.'timeout-minutes' -ne 8) {
        throw 'Preserve the 360-second MSI supervisor budget and independent eight-minute step deadline.'
    }
    $linux = $Phases.test.steps | Where-Object { $_['name'] -ceq 'Test on Linux' }
    if (!$linux.run.Contains('monitor-test-containers.ps1') -or !$linux.run.Contains('trap stop_diagnostics EXIT') -or
        $linux.env.TEST_TIMEOUT -cne '${{ matrix.category == ''Oracle'' && ''40m'' || ''20m'' }}' -or
        $linux.env.MONITOR_TIMEOUT -cne '${{ matrix.category == ''Oracle'' && ''42m'' || ''25m'' }}' -or
        $Phases.test.'timeout-minutes' -cne '${{ matrix.category == ''Oracle'' && 45 || 30 }}') {
        throw 'Preserve bounded database tests, Oracle budgets and failure diagnostics.'
    }
}

function Assert-WorkflowPolicy {
    param(
        [string] $Workflow,
        [string] $Preflight = $preflightScript,
        [hashtable]$Phases = $phases
    )

    # Inspect only this scheduling contract. actionlint checks full YAML and
    # expression syntax; these assertions reject accidental gate bypasses.
    $jobs = @{}
    foreach ($match in [regex]::Matches($Workflow, '(?ms)^  ([a-z][a-z0-9-]*):\r?\n(.*?)(?=^  [a-z][a-z0-9-]*:\r?\n|\z)')) {
        $jobs[$match.Groups[1].Value] = $match.Groups[2].Value
    }

    foreach ($job in $expensiveJobs) {
        $expectedDependencies = if ($job -ceq 'cli-distributions') {
            '    needs: [build-code, fast-tests, validation-policy, cli-distribution-build]'
        } else {
            '    needs: [build-code, fast-tests, validation-policy]'
        }
        if (!$jobs.ContainsKey($job) -or $jobs[$job] -notmatch ('(?m)^' + [regex]::Escape($expectedDependencies) + '\r?$')) {
            throw "Expensive job $job must depend on Build, validation policy and both isolated test lanes."
        }
        if ($job -eq 'analyze') {
            if (!$jobs[$job].Contains("    if: $analysisCondition") -or $jobs[$job] -match '(?m)^    continue-on-error:') {
                throw 'CodeQL must preserve staged PR gates and independent main/schedule baselines.'
            }
        }
        elseif ($jobs[$job] -match '(?m)^    (if|continue-on-error):') {
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
    if (!$aggregateJob -or !$aggregateJob.Contains($expectedNeeds) -or !$aggregateJob.Contains($aggregateCondition)) {
        throw 'The CI result must always evaluate every required producer.'
    }
    if (!$aggregateJob.Contains('CI_NEEDS_JSON: ${{ toJSON(needs) }}') -or !$aggregateJob.Contains('./scripts/Assert-CiResults.ps1 -NeedsJson $env:CI_NEEDS_JSON')) {
        throw 'The CI result must validate actual dependency results with the tested gate.'
    }
    if ($jobs['report'] -notmatch '(?m)^    needs: \[fast-tests, test, cli-distributions\]\r?$') {
        throw 'The test report must collect both test tiers.'
    }
    $fastLanes = @($Phases['fast-tests'].strategy.matrix.include)
    if (@($Phases['test'].strategy.matrix.include | Where-Object category -CEQ 'Basic_tests').Count -ne 0 -or
        $fastLanes.Count -ne 2 -or @($fastLanes | Where-Object category -CEQ 'Basic_tests').Count -ne 2 -or
        (@($fastLanes.os | Sort-Object) -join ',') -cne 'ubuntu-latest,windows-latest') {
        throw 'Linux and Windows isolated tests must run once after preflight.'
    }
    if (!$Preflight.Contains('-Path .github/scripts -Filter monitor-test-containers.Tests.ps1') -or $jobs['fast-tests'].Contains('monitor-test-containers.Tests.ps1') -or $jobs['test'].Contains('monitor-test-containers.Tests.ps1')) {
        throw 'Container monitor regressions must run before compiling test projects.'
    }
    $callers = @{
        'build-code' = @('ci-build.yml', 'Build')
        'fast-tests' = @('ci-fast-tests.yml', 'Isolated tests')
        'analyze' = @('ci-security-analysis.yml', 'Security analysis')
        'test' = @('ci-database-tests.yml', 'Database tests')
        'cli-distribution-build' = @('ci-cli-distribution-build.yml', 'CLI distribution build')
        'cli-distributions' = @('ci-cli-distributions.yml', 'CLI distributions')
        'packages' = @('ci-packages.yml', 'Packages')
        'standalone' = @('ci-standalone.yml', 'Standalone CLI')
        'docker' = @('ci-docker.yml', 'Docker')
        'report' = @('ci-report.yml', 'Test report')
    }
    foreach ($id in $callers.Keys) {
        $file, $name = $callers[$id]
        if (!$jobs[$id].Contains("    uses: ./.github/workflows/$file") -or
            !$jobs[$id].Contains("    name: $name") -or
            $Phases[$id].Contains('continue-on-error') -or $Phases[$id].Contains('_workflowLeafIf')) {
            throw "Reusable CI phase $id must preserve its exact caller identity and required leaf execution."
        }
    }
    if (!$jobs['pr-validation'].Contains('    name: PR validation')) {
        throw 'The required PR validation check name must remain stable.'
    }
    Assert-CiPhaseCoverage -Phases $Phases
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
$bypassedPreparation = $workflow.Replace('needs: [build-code, fast-tests, validation-policy, cli-distribution-build]', 'needs: [build-code, fast-tests, validation-policy]')
Assert-Rejected -Action { Assert-WorkflowPolicy -Workflow $bypassedPreparation } -ExpectedMessage 'must depend'
$skippedAggregate = $workflow.Replace('    if: always()', '    if: success()')
Assert-Rejected -Action { Assert-WorkflowPolicy -Workflow $skippedAggregate } -ExpectedMessage 'must always evaluate'
$missingProducer = $workflow.Replace('needs: [build-code, fast-tests, analyze, test, cli-distribution-build, cli-distributions, report, packages, standalone, docker, validation-policy, pr-validation]', 'needs: [build-code, fast-tests, analyze, test, cli-distribution-build, cli-distributions, report, packages, standalone, docker, validation-policy]')
Assert-Rejected -Action { Assert-WorkflowPolicy -Workflow $missingProducer } -ExpectedMessage 'must always evaluate'
$missingMonitorTests = $preflightScript.Replace('-Path .github/scripts -Filter monitor-test-containers.Tests.ps1', '-Path scripts -Filter skipped.ps1')
Assert-Rejected -Action { Assert-WorkflowPolicy -Workflow $workflow -Preflight $missingMonitorTests } -ExpectedMessage 'Container monitor regressions must run'
$ungatedBuilds = $workflow.Replace('    needs: validation-policy', '')
Assert-Rejected -Action { Assert-WorkflowPolicy -Workflow $ungatedBuilds } -ExpectedMessage 'must depend on build-independent checks'
$bypassedChecks = $workflow.Replace('uses: ./.github/actions/preflight', 'run: Write-Host skipped')
Assert-Rejected -Action { Assert-WorkflowPolicy -Workflow $bypassedChecks } -ExpectedMessage 'must run the shared'

$renamedCaller = $workflow.Replace('    name: Standalone CLI', '    name: Other caller')
Assert-Rejected -Action { Assert-WorkflowPolicy -Workflow $renamedCaller } -ExpectedMessage 'exact caller identity'
$wrongWorkflow = $workflow.Replace('uses: ./.github/workflows/ci-standalone.yml', 'uses: ./.github/workflows/ci-packages.yml')
Assert-Rejected -Action { Assert-WorkflowPolicy -Workflow $wrongWorkflow } -ExpectedMessage 'exact caller identity'
$missingFastLane = $phases | ConvertTo-Json -Depth 100 | ConvertFrom-Json -AsHashtable
$missingFastLane['fast-tests'].strategy.matrix.include = @($missingFastLane['fast-tests'].strategy.matrix.include[0])
Assert-Rejected -Action { Assert-WorkflowPolicy -Workflow $workflow -Phases $missingFastLane } -ExpectedMessage 'isolated tests must run once'
$optionalLeaf = $phases | ConvertTo-Json -Depth 100 | ConvertFrom-Json -AsHashtable
$optionalLeaf.standalone['continue-on-error'] = $true
Assert-Rejected -Action { Assert-WorkflowPolicy -Workflow $workflow -Phases $optionalLeaf } -ExpectedMessage 'required leaf execution'
$missingProvider = $phases | ConvertTo-Json -Depth 100 | ConvertFrom-Json -AsHashtable
$missingProvider.test.strategy.matrix.include = @($missingProvider.test.strategy.matrix.include | Where-Object category -CNE 'Oracle')
Assert-Rejected -Action { Assert-WorkflowPolicy -Workflow $workflow -Phases $missingProvider } -ExpectedMessage 'all eleven library'
$missingRuntime = $phases | ConvertTo-Json -Depth 100 | ConvertFrom-Json -AsHashtable
(Get-ActionStep $missingRuntime.test 'actions/setup-dotnet').with.'dotnet-version' = "8.0.x`n10.0.x"
Assert-Rejected -Action { Assert-WorkflowPolicy -Workflow $workflow -Phases $missingRuntime } -ExpectedMessage 'earlier runtime setup'
$lostDiagnostics = $phases | ConvertTo-Json -Depth 100 | ConvertFrom-Json -AsHashtable
(Get-ActionStep $lostDiagnostics.test 'actions/upload-artifact').if = 'success()'
Assert-Rejected -Action { Assert-WorkflowPolicy -Workflow $workflow -Phases $lostDiagnostics } -ExpectedMessage 'artifact names on failure'

foreach ($deadline in @($null, 30)) {
    $unboundedInstaller = $phases | ConvertTo-Json -Depth 100 | ConvertFrom-Json -AsHashtable
    $lifecycle = $unboundedInstaller.standalone.steps | Where-Object { $_['name'] -ceq 'Verify installed MSI, major upgrade and uninstall' }
    if ($null -eq $deadline) {
        $lifecycle.Remove('timeout-minutes')
    } else {
        $lifecycle['timeout-minutes'] = $deadline
    }
    Assert-Rejected -Action { Assert-WorkflowPolicy -Workflow $workflow -Phases $unboundedInstaller } -ExpectedMessage 'independent eight-minute step deadline'
}

$sqlServerFlag = '${{ matrix.category == ''SqlServer'' && ''true'' || ''false'' }}'
$oracleFlag = '${{ matrix.category == ''Oracle'' && ''true'' || ''false'' }}'
$combinedCasingFlag = '${{ (matrix.category == ''SqlServer'' || matrix.category == ''Oracle'') && ''true'' || ''false'' }}'
$wrongProviderFlag = '${{ matrix.category == ''SqlServerCaseSensitive'' && ''true'' || ''false'' }}'
$flagCases = @(
    @{ Step = 'Test on Linux'; Name = 'GRATE_SQLSERVER_SCOPED_POOLING'; Other = @($oracleFlag, $combinedCasingFlag) }
    @{ Step = 'Test on Linux'; Name = 'GRATE_ORACLE_SCOPED_POOLING'; Other = @($sqlServerFlag, $combinedCasingFlag) }
    @{ Step = 'Test on Linux'; Name = 'GRATE_REPRODUCIBLE_TABLE_CASINGS'; Other = @($sqlServerFlag, $oracleFlag) }
    @{ Step = 'Test on Windows'; Name = 'GRATE_SQLSERVER_SCOPED_POOLING'; Other = @($oracleFlag, $combinedCasingFlag) }
    @{ Step = 'Test on Windows'; Name = 'GRATE_REPRODUCIBLE_TABLE_CASINGS'; Other = @($oracleFlag, $combinedCasingFlag) }
)
foreach ($case in $flagCases) {
    foreach ($value in (@($null, 'false', 'true', $wrongProviderFlag) + $case.Other)) {
        $wrongPoolingScope = $phases | ConvertTo-Json -Depth 100 | ConvertFrom-Json -AsHashtable
        $step = $wrongPoolingScope.test.steps | Where-Object { $_['name'] -ceq $case.Step }
        if ($null -eq $value) {
            $step.env.Remove($case.Name)
        } else {
            $step.env[$case.Name] = $value
        }
        Assert-Rejected -Action {
            Assert-WorkflowPolicy -Workflow $workflow -Phases $wrongPoolingScope
        } -ExpectedMessage 'provider-specific pooling and casing flags'
    }
}
foreach ($name in @('GRATE_SQLSERVER_SCOPED_POOLING', 'GRATE_ORACLE_SCOPED_POOLING', 'GRATE_REPRODUCIBLE_TABLE_CASINGS')) {
    foreach ($location in @('job', 'setup', 'windows-oracle')) {
        if ($location -eq 'windows-oracle' -and $name -cne 'GRATE_ORACLE_SCOPED_POOLING') {
            continue
        }
        $misplacedFlag = $phases | ConvertTo-Json -Depth 100 | ConvertFrom-Json -AsHashtable
        if ($location -eq 'job') {
            $misplacedFlag.test.env = @{ $name = 'false' }
        } elseif ($location -eq 'setup') {
            $step = Get-ActionStep $misplacedFlag.test 'actions/setup-dotnet'
            $step.env = @{ $name = 'true' }
        } else {
            $step = $misplacedFlag.test.steps | Where-Object { $_['name'] -ceq 'Test on Windows' }
            $step.env[$name] = $oracleFlag
        }
        Assert-Rejected -Action {
            Assert-WorkflowPolicy -Workflow $workflow -Phases $misplacedFlag
        } -ExpectedMessage 'provider-specific pooling and casing flags'
    }
}

Write-Host "PASS: staged wiring, all-success aggregate, $rejectionCount per-job rejection cases, empty input and scheduling mutations."
