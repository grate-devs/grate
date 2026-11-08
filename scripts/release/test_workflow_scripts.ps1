#!/usr/bin/env pwsh
. "$PSScriptRoot/workflow_test_helpers.ps1"
$checked = 0
foreach ($name in @('build.yml', 'ci.yml', 'integration-tests.yml', 'docker-access-check.yml', 'docker-distribution.yml', 'winget-validation.yml')) {
    $workflow = Read-Workflow $name
    foreach ($jobName in $workflow.jobs.Keys) {
        $job = $workflow.jobs[$jobName]
        foreach ($step in $job.steps) {
            if (!$step.run) { continue }
            Assert-Policy ($step.run -notmatch '\bpython(?:3)?\b|\.py\b') "Python caller remains in $name/$jobName."
            foreach ($match in [regex]::Matches($step.run, '(?:\./)?(?:\.github/scripts|scripts|installers|examples)/[\w./-]+\.ps1|(?:\./)?build-docker-local\.ps1')) {
                Assert-Policy (Test-Path -LiteralPath "$repositoryRoot/$($match.Value)" -PathType Leaf) "Missing workflow script: $($match.Value)"
            }
            $shell = $step.shell
            if (!$shell) { $shell = $job.defaults.run.shell }
            if ($shell -ne 'pwsh') { continue }
            # Expressions are supplied by Actions before invoking PowerShell.
            $script = [regex]::Replace($step.run, '\$\{\{.*?\}\}', 'fixture')
            $tokens = $null
            $errors = $null
            $null = [Management.Automation.Language.Parser]::ParseInput($script, [ref]$tokens, [ref]$errors)
            Assert-Policy ($errors.Count -eq 0) "PowerShell syntax in $name/$jobName/$($step.name): $($errors.Message -join '; ')"
            $checked++
        }
    }
}
Assert-Policy ($checked -gt 20) 'Expected PowerShell workflow steps were not selected.'
# Exercise the workflow's actual assignment: PowerShell converts an array placed
# in an environment variable to a space-separated string unless joined explicitly.
$preflight = (Read-Workflow 'build.yml').jobs['build-docker-image'].steps | Where-Object name -CEQ 'Verify OCI archive and preflight intended publication before the release gate'
$assignment = [regex]::Match($preflight.run, '(?m)^\s*\$env:DOCKER_TAGS = .+$').Value
Assert-Policy ([bool]$assignment) 'Require explicit Docker tag selection before release preflight.'
$savedEnvironment = @{}
foreach ($key in @('VERSION', 'PRERELEASE', 'DOCKER_TAGS')) { $savedEnvironment[$key] = [Environment]::GetEnvironmentVariable($key) }
try {
    Push-Location $repositoryRoot
    . "$PSScriptRoot/copy_docker_release.ps1"
    $env:VERSION = '2.3.4'
    foreach ($prerelease in @('false', 'true')) {
        $env:PRERELEASE = $prerelease
        & ([scriptblock]::Create($assignment))
        $selected = @(Get-SelectedReleaseTags $env:DOCKER_TAGS)
        $expected = if ($prerelease -ceq 'true') { '2.3.4' } else { '2.3.4,latest' }
        Assert-Policy (($selected -join ',') -ceq $expected) "Workflow preflight tag assignment failed for prerelease=$prerelease."
    }
} finally {
    Pop-Location
    foreach ($key in $savedEnvironment.Keys) { [Environment]::SetEnvironmentVariable($key, $savedEnvironment[$key]) }
}
Write-Host "PASS: $checked inline PowerShell steps parse; workflow script paths exist and no Python callers remain."
