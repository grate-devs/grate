#!/usr/bin/env pwsh
. "$PSScriptRoot/workflow_test_helpers.ps1"

function Assert-CodeQLWorkflowPolicy {
    param(
        [hashtable] $job
    )
    Assert-Policy ($job.name -ceq 'Analyze Code Security') 'Preserve the CodeQL check name.'
    Assert-Policy ($job.'runs-on' -ceq 'windows-latest') 'MSI C++ extraction requires Windows.'

    $init = Get-ActionStep $job 'github/codeql-action/init'
    $buildSolution = $job.steps | Where-Object name -CEQ 'Build .NET solution for CodeQL' | Select-Object -First 1
    $analyze = Get-ActionStep $job 'github/codeql-action/analyze'
    Assert-Policy ($null -ne $init -and $null -ne $buildSolution -and $null -ne $analyze) 'Require CodeQL initialization, explicit solution build and analysis.'
    Assert-Policy (!$init.with.ContainsKey('build-mode')) 'The build-mode input only supports a single language per job.'
    Assert-Policy ($null -eq (Get-ActionStep $job 'github/codeql-action/autobuild')) 'Do not autodetect an example solution.'
    Assert-Policy ($buildSolution.shell -ceq 'pwsh') 'The .NET solution build requires PowerShell.'
    # Full recompilation, without framework/project filters, lets the tracer observe
    # every project and supported target in the maintained solution.
    $expectedCommand = 'dotnet build grate.slnx --configuration Release --no-incremental -p:UseSharedCompilation=false'
    Assert-Policy ($buildSolution.run.Trim() -ceq $expectedCommand) 'Recompile the complete root SLNX solution with shared compilation disabled.'
    $languages = @($init.with.languages -split ',' | ForEach-Object { $_.Trim() } | Sort-Object)
    Assert-Policy (($languages -join ',') -ceq 'actions,c-cpp,csharp') 'Analyze C#, native MSI C++ and workflows; do not retain removed Python sources.'

    $steps = @($job.steps)
    $managedBuildIsOrdered = (
        $steps.IndexOf($init) -lt $steps.IndexOf($buildSolution) -and
        $steps.IndexOf($buildSolution) -lt $steps.IndexOf($analyze)
    )
    Assert-Policy $managedBuildIsOrdered '.NET compilation must run between initialization and analysis.'

    $script = 'installers/msi/native/Build-UpgradeActions.ps1'
    Assert-Policy (Test-Path -LiteralPath "$repositoryRoot/$script" -PathType Leaf) 'Require actual native MSI build helper.'

    $build = $steps | Where-Object { $_.run -clike "*$script*" } | Select-Object -First 1
    Assert-Policy ($null -ne $build) 'Extract the actual MSI compiler invocation.'
    Assert-Policy ($build.shell -ceq 'pwsh') 'Native MSI build requires PowerShell.'

    $buildHasExpectedArguments = (
        $build.run.Contains('-Architecture x64') -and
        $build.run.Contains('-OutputDirectory "$env:RUNNER_TEMP/')
    )
    Assert-Policy $buildHasExpectedArguments 'Preserve architecture and isolated output directory.'

    $nativeBuildIsOrdered = (
        $steps.IndexOf($init) -lt $steps.IndexOf($build) -and
        $steps.IndexOf($build) -lt $steps.IndexOf($analyze)
    )
    Assert-Policy $nativeBuildIsOrdered 'Native compilation must run between CodeQL init and analysis.'

    Assert-Policy ($job.permissions.'security-events' -ceq 'write') 'CodeQL must be able to publish analysis.'
    Assert-Policy (!$job.ContainsKey('if') -and !$job.'continue-on-error') 'CodeQL job cannot skip or ignore failures.'
    foreach ($step in $steps) {
        $stepCannotBypassFailures = (
            !$step.ContainsKey('if') -and
            !$step.'continue-on-error' -and
            $step.run -cnotlike '*|| true*'
        )
        Assert-Policy $stepCannotBypassFailures 'CodeQL steps cannot bypass compilation failures.'
    }

    $builder = Get-Content -LiteralPath "$repositoryRoot/$script" -Raw
    $builderPropagatesFailures = (
        $builder.Contains("`$ErrorActionPreference = 'Stop'") -and
        $builder.Contains('if ($LASTEXITCODE -ne 0')
    )
    Assert-Policy $builderPropagatesFailures 'Native compiler failures must reach the caller.'

}

$job = (Read-Workflow 'ci.yml').jobs.analyze
Assert-CodeQLWorkflowPolicy -job $job

function Assert-RejectedPolicy {
    param(
        [hashtable] $Job,
        [string] $ExpectedMessage
    )

    try {
        Assert-CodeQLWorkflowPolicy -job $Job
    }
    catch {
        Assert-Policy ($_.Exception.Message -ceq $ExpectedMessage) "Unexpected policy rejection: $($_.Exception.Message)"
        return
    }
    throw "Expected policy rejection: $ExpectedMessage"
}

# Reject the observed example-solution regression and implicit discovery using
# isolated inputs; leave the real workflow unchanged throughout these checks.
foreach ($solution in @('examples/test-integration/sample-test-integration/sample-test-integration.sln', '')) {
    $isolatedJob = ConvertTo-Json -InputObject $job -Depth 30 | ConvertFrom-Json -AsHashtable
    $build = $isolatedJob.steps | Where-Object name -CEQ 'Build .NET solution for CodeQL'
    $build.run = $build.run.Replace('grate.slnx', $solution)
    Assert-RejectedPolicy $isolatedJob 'Recompile the complete root SLNX solution with shared compilation disabled.'
}

$isolatedJob = ConvertTo-Json -InputObject $job -Depth 30 | ConvertFrom-Json -AsHashtable
$steps = @($isolatedJob.steps)
$initIndex = $steps.IndexOf((Get-ActionStep $isolatedJob 'github/codeql-action/init'))
$buildIndex = $steps.IndexOf(($steps | Where-Object name -CEQ 'Build .NET solution for CodeQL'))
$steps[$initIndex], $steps[$buildIndex] = $steps[$buildIndex], $steps[$initIndex]
$isolatedJob.steps = $steps
Assert-RejectedPolicy $isolatedJob '.NET compilation must run between initialization and analysis.'

$isolatedJob = ConvertTo-Json -InputObject $job -Depth 30 | ConvertFrom-Json -AsHashtable
$steps = @($isolatedJob.steps)
$analysisIndex = $steps.IndexOf((Get-ActionStep $isolatedJob 'github/codeql-action/analyze'))
$buildIndex = $steps.IndexOf(($steps | Where-Object name -CEQ 'Build native MSI upgrade action for CodeQL'))
$steps[$analysisIndex], $steps[$buildIndex] = $steps[$buildIndex], $steps[$analysisIndex]
$isolatedJob.steps = $steps
Assert-RejectedPolicy $isolatedJob 'Native compilation must run between CodeQL init and analysis.'

$isolatedJob = ConvertTo-Json -InputObject $job -Depth 30 | ConvertFrom-Json -AsHashtable
$build = $isolatedJob.steps | Where-Object name -CEQ 'Build .NET solution for CodeQL'
$build.'continue-on-error' = $true
Assert-RejectedPolicy $isolatedJob 'CodeQL steps cannot bypass compilation failures.'

Write-Host 'PASS: CodeQL explicit solution build, native extraction, permissions and five policy regressions.'
