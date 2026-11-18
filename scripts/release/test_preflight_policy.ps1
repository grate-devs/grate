#!/usr/bin/env pwsh
. "$PSScriptRoot/workflow_test_helpers.ps1"

function Assert-PreflightDependency {
    param(
        [System.Collections.IDictionary] $Job,
        [string] $CheckJob
    )

    Assert-Policy (@($Job.needs).Count -eq 1 -and $Job.needs -ceq $CheckJob) 'Build must wait for preflight.'
    Assert-Policy (!$Job.if -and !$Job.'continue-on-error') 'Build cannot bypass preflight failure.'
}

$contracts = @(
    @{
        Workflow = 'ci.yml'
        CheckJob = 'validation-policy'
        BuildJobs = @('build-code', 'fast-tests')
    },
    @{
        Workflow = 'build.yml'
        CheckJob = 'validate-release-policy'
        BuildJobs = @('set-version-number')
    },
    @{
        Workflow = 'skill-installation.yml'
        CheckJob = 'docs'
        BuildJobs = @('install')
    },
    @{
        Workflow = 'winget-validation.yml'
        CheckJob = 'preflight'
        BuildJobs = @('prepare')
    }
)

foreach ($contract in $contracts) {
    $workflow = Read-Workflow $contract.Workflow
    $preflight = $workflow.jobs[$contract.CheckJob]
    Assert-Policy (!$preflight.needs -and !$preflight.'continue-on-error') 'Preflight must run first and propagate failures.'
    Assert-Policy ($preflight.steps.uses -ccontains './.github/actions/preflight') 'Require the same shared preflight action.'
    foreach ($name in $contract.BuildJobs) {
        $job = $workflow.jobs[$name]
        Assert-PreflightDependency -Job $job -CheckJob $contract.CheckJob

        # Removing the dependency or overriding its success condition must fail,
        # even when every other workflow job would succeed.
        foreach ($mutation in @('needs', 'if', 'continue-on-error')) {
            $mutated = $job.Clone()
            $mutated[$mutation] = switch ($mutation) {
                'needs' { $null }
                'if' { 'always()' }
                'continue-on-error' { $true }
            }
            $rejected = $false
            try {
                Assert-PreflightDependency -Job $mutated -CheckJob $contract.CheckJob
            }
            catch {
                $rejected = $true
            }
            Assert-Policy $rejected "Preflight bypass was accepted in $($contract.Workflow)/$name."
        }
    }
}

function Assert-CompatibilityPreflight {
    param(
        [System.Collections.IDictionary] $Ci,
        [System.Collections.IDictionary] $Integration
    )

    $call = $Ci.jobs.compatibility
    Assert-Policy ($call.uses -ceq './.github/workflows/integration-tests.yml' -and
        $call.if -ceq "github.event_name == 'pull_request'" -and
        $call.needs -ceq 'validation-policy' -and !$call.'continue-on-error' -and !$call.secrets -and !$call.permissions) 'PR compatibility must wait for successful preflight in its own run.'
    Assert-Policy ($Integration.on.Count -eq 3 -and
        $Integration.on.Contains('workflow_call') -and $Integration.on.Contains('workflow_dispatch') -and
        $Integration.on.push.branches.Count -eq 1 -and $Integration.on.push.branches[0] -ceq 'main') 'Keep direct push and manual integrations, with PRs using one shared preflight.'
    Assert-Policy ($Integration.permissions.Count -eq 1 -and $Integration.permissions.contents -ceq 'read' -and
        $Integration.concurrency.group -ceq 'integration-tests-${{ github.event_name }}-${{ github.ref }}') 'Keep compatibility read-only and in a different concurrency group from the caller.'
    foreach ($job in @('setup-test-environment', 'integration-test', 'teardown-test-environment')) {
        Assert-Policy ($Integration.jobs[$job].Contains('if') -and $Integration.jobs[$job].if -eq $false) 'External integration jobs must remain disabled.'
    }

    $localPreflight = $Integration.jobs.preflight
    $version = $Integration.jobs.'set-version-number'
    $sharedPrEntry = @(
        "github.event_name == 'pull_request'"
        "github.ref == format('refs/pull/{0}/merge', github.event.pull_request.number)"
        "github.workflow_ref == format('{0}/.github/workflows/ci.yml@{1}', github.repository, github.ref)"
    ) -join ' && '
    $preflightCondition = ('${{ !(' + $sharedPrEntry + ') }}')
    $versionCondition = ('${{ !cancelled() && (needs.preflight.result == ''success'' || ' +
        '(needs.preflight.result == ''skipped'' && ' + $sharedPrEntry + ')) }}')
    Assert-Policy (($localPreflight.if -replace '\s+', ' ') -ceq $preflightCondition -and
        !$localPreflight.needs -and !$localPreflight.'continue-on-error' -and
        $localPreflight.steps.uses -ccontains './.github/actions/preflight') 'Skip local preflight only for the shared PR entry.'
    Assert-Policy ($version.needs -ceq 'preflight' -and !$version.'continue-on-error' -and
        ($version.if -replace '\s+', ' ') -ceq $versionCondition) 'Version selection requires successful local preflight or an intentional skip by the exact shared PR caller.'
    foreach ($job in @('build-standalone', 'build-tests')) {
        Assert-PreflightDependency -Job $Integration.jobs[$job] -CheckJob 'set-version-number'
    }

    $database = $Integration.jobs.'cli-database-integration-tests'
    Assert-Policy ($database.strategy.matrix.database.Count -eq 21 -and
        @($database.strategy.matrix.database.name | Sort-Object -Unique).Count -eq 21 -and
        ($database.strategy.matrix.variant -join ',') -ceq 'All,Slim' -and
        ($database.needs -join ',') -ceq 'set-version-number,build-standalone,build-tests' -and
        !$database.if -and !$database.'continue-on-error') 'Keep all 42 compatibility lanes behind the preflight and prepared payloads.'

    $upload = Get-ActionStep $database 'actions/upload-artifact'
    $download = Get-ActionStep $Integration.jobs.report 'actions/download-artifact'
    $report = Get-ActionStep $Integration.jobs.report 'actions/upload-artifact'
    Assert-Policy ($upload.with.name -ceq 'Compatibility ${{ matrix.variant }} CLI ${{ matrix.database.name }} results' -and
        $download.with.pattern -ceq 'Compatibility * CLI * results' -and
        $report.with.name -ceq 'Compatibility HTML test report') 'Keep compatibility reports distinct within the shared run.'
}

$ci = Read-Workflow 'ci.yml' -Raw
$integration = Read-Workflow 'integration-tests.yml' -Raw
Assert-CompatibilityPreflight -Ci $ci -Integration $integration
$brokenCall = $ci | ConvertTo-Json -Depth 100 | ConvertFrom-Json -AsHashtable
$brokenCall.jobs.compatibility.Remove('needs')
try {
    Assert-CompatibilityPreflight -Ci $brokenCall -Integration $integration
    throw 'Ungated compatibility call was accepted.'
}
catch {
    if ($_.Exception.Message -cne 'PR compatibility must wait for successful preflight in its own run.') {
        throw
    }
}
$brokenIntegration = $integration | ConvertTo-Json -Depth 100 | ConvertFrom-Json -AsHashtable
$brokenIntegration.jobs.'set-version-number'.if = '${{ !cancelled() }}'
try {
    Assert-CompatibilityPreflight -Ci $ci -Integration $brokenIntegration
    throw 'Failed or accidentally skipped preflight could start version selection.'
}
catch {
    if ($_.Exception.Message -cne 'Version selection requires successful local preflight or an intentional skip by the exact shared PR caller.') {
        throw
    }
}

$dockerPolicy = (Read-Workflow 'docker-distribution.yml').jobs.policy
Assert-Policy ($dockerPolicy.steps.uses -ccontains './.github/actions/preflight') 'Docker policy must use the same checks.'

$action = Get-Content -LiteralPath "$repositoryRoot/.github/actions/preflight/action.yml" -Raw | ConvertFrom-Yaml
Assert-Policy ($action.runs.using -ceq 'composite') 'Share steps without adding cross-workflow coordination.'
Assert-Policy ($action.runs.steps.run -ccontains './scripts/ci/Invoke-Preflight.ps1') 'Run the same script checks locally and in Actions.'
Assert-Policy ($action.runs.steps.uses -ccontains 'actions/jekyll-build-pages@v1') 'Check generated documentation before compiling grate.'
Assert-Policy (($action.runs.steps.run -join "`n").Contains('./scripts/release/check_docker_oci_copy.ps1')) 'Preserve the local OCI digest check.'

foreach ($step in $action.runs.steps) {
    Assert-Policy (!$step.if -and !$step.'continue-on-error') 'Shared checks cannot bypass failures.'
    if ($step.run) {
        $tokens = $null
        $errors = $null
        $null = [Management.Automation.Language.Parser]::ParseInput($step.run, [ref]$tokens, [ref]$errors)
        Assert-Policy ($errors.Count -eq 0) 'Shared PowerShell checks must parse.'
    }
}

Write-Host 'PASS: shared preflight gates five build workflows, including PR compatibility. Missing dependencies and failure bypasses are rejected.'
