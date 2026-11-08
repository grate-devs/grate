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
        Workflow = 'integration-tests.yml'
        CheckJob = 'preflight'
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

Write-Host 'PASS: shared preflight gates five build workflows; missing dependencies and failure bypasses are rejected.'
