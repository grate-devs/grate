param(
    [string] $RepositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
)

$ErrorActionPreference = 'Stop'

function Assert-Policy {
    param(
        [bool] $Condition,
        [string] $Message
    )

    if (!$Condition) {
        throw $Message
    }
}

function Get-WorkflowJob {
    param(
        [string] $Workflow,
        [string] $Id
    )

    $pattern = "(?ms)^  ${Id}:\r?\n(?<body>.*?)(?=^  [\w-]+:|\z)"
    $match = [regex]::Match($Workflow, $pattern)
    Assert-Policy $match.Success "Missing job: $Id"
    return $match.Groups['body'].Value
}

function Assert-SecurityTriggers {
    param(
        [string] $Workflow
    )

    Assert-Policy ($Workflow -match '(?m)^  pull_request:') 'Keep PR analysis enabled.'
    Assert-Policy ($Workflow -match '(?m)^  push:') 'Keep main analysis enabled.'
    Assert-Policy ($Workflow -match '(?m)^  schedule:') 'Keep periodic analysis enabled.'

    $privilegedOrFiltered = $Workflow -match '(?m)^  pull_request_target:|^    paths(-ignore)?:'
    Assert-Policy (!$privilegedOrFiltered) 'Do not filter or privilege security PR checks.'
}

function Assert-CodeqlExtraction {
    param(
        [string] $Job
    )

    Assert-Policy ($Job -match 'name: Analyze Code Security') 'Preserve the CodeQL check name.'
    Assert-Policy ($Job -match 'runs-on: windows-latest') 'Extract the Windows MSI code on Windows.'
    Assert-Policy ($Job -notmatch 'continue-on-error:') 'Propagate analysis failures.'
    Assert-Policy ($Job -match 'languages: csharp, c-cpp, actions') 'Keep the maintained languages after the Python-to-PowerShell migration.'

    $buildCommand = 'dotnet build grate.slnx --configuration Release --no-incremental -p:UseSharedCompilation=false'
    $init = $Job.IndexOf('github/codeql-action/init@')
    $managedBuild = $Job.IndexOf($buildCommand)
    $nativeBuild = $Job.IndexOf('./installers/msi/native/Build-UpgradeActions.ps1 -Architecture x64')
    $analyze = $Job.IndexOf('github/codeql-action/analyze@')
    $buildsAreTraced = (
        $init -ge 0 -and
        $managedBuild -gt $init -and $nativeBuild -gt $init -and
        $analyze -gt $managedBuild -and $analyze -gt $nativeBuild
    )
    Assert-Policy $buildsAreTraced 'Trace the full SLNX solution and native compilation between CodeQL init and analyze.'
}

function Assert-StagedCiJobs {
    param(
        [string] $Workflow
    )

    $producers = @('build-code', 'fast-tests', 'test', 'packages', 'standalone', 'docker')
    foreach ($producer in $producers) {
        $job = Get-WorkflowJob $Workflow $producer
        Assert-Policy ($job -notmatch '(?m)^    if:|continue-on-error:') "Preserve the staged success-only gate for $producer."
        Assert-Policy ($job -match '(?m)^    needs:') "Keep $producer downstream of PR-only preflight."
    }

    $prEvents = "if: .*github.event_name == 'pull_request'.*github.event_name == 'workflow_dispatch'"
    foreach ($jobId in @('validation-policy', 'report', 'ci-result')) {
        $job = Get-WorkflowJob $Workflow $jobId
        Assert-Policy ($job -match $prEvents) "Keep $jobId limited to PR/manual validation."
    }

    $report = Get-WorkflowJob $Workflow 'report'
    Assert-Policy ($report -match 'if: always\(\) &&') 'Retain failure reporting for PR/manual tests.'
}

function Get-CodeqlCondition {
    param(
        [string] $Job
    )

    $match = [regex]::Match($Job, '(?m)^    if: \$\{\{ (.+) \}\}\r?$')
    Assert-Policy $match.Success 'Require an explicit event-aware CodeQL gate.'
    $condition = $match.Groups[1].Value
    Assert-Policy ($condition.Contains('!cancelled()')) 'CodeQL must stop when its workflow is cancelled.'

    # Translate only the operators and context names used by this condition.
    # The independent decision table below supplies its expected behavior.
    $expression = $condition.Replace('!cancelled()', '(-not $IsCancelled)')
    $expression = $expression.Replace('github.event_name', '$EventName')
    $expression = $expression.Replace('needs.build-code.result', '$BuildResult')
    $expression = $expression.Replace('needs.fast-tests.result', '$FastResult')
    $expression = $expression.Replace('needs.validation-policy.result', '$PolicyResult')
    $expression = $expression.Replace('&&', '-and').Replace('||', '-or').Replace('==', '-eq')
    $parameters = 'param($EventName, $BuildResult, $FastResult, $PolicyResult, $IsCancelled) '
    return [scriptblock]::Create($parameters + $expression)
}

function Get-PrerequisiteCases {
    $states = @('success', 'failure', 'cancelled', 'skipped', $null)
    foreach ($build in $states) {
        foreach ($fastTests in $states) {
            foreach ($policy in $states) {
                [pscustomobject] @{
                    Build = $build
                    FastTests = $fastTests
                    Policy = $policy
                    AllSucceeded = $build -eq 'success' -and $fastTests -eq 'success' -and $policy -eq 'success'
                }
            }
        }
    }
}

function Assert-CodeqlScheduling {
    param(
        [string] $Job
    )

    $evaluate = Get-CodeqlCondition $Job
    $prerequisites = @(Get-PrerequisiteCases)
    $caseCount = 0
    foreach ($eventName in @('push', 'schedule', 'pull_request', 'workflow_dispatch', 'workflow_run')) {
        foreach ($isCancelled in @($false, $true)) {
            foreach ($case in $prerequisites) {
                $isBaseline = $eventName -in @('push', 'schedule')
                $isValidatedPr = $eventName -in @('pull_request', 'workflow_dispatch') -and $case.AllSucceeded
                $expected = !$isCancelled -and ($isBaseline -or $isValidatedPr)
                $actual = [bool] (& $evaluate $eventName $case.Build $case.FastTests $case.Policy $isCancelled)
                $context = "$eventName/$($case.Build)/$($case.FastTests)/$($case.Policy)/cancelled=$isCancelled"
                Assert-Policy ($actual -eq $expected) "Incorrect CodeQL scheduling: $context."
                $caseCount++
            }
        }
    }
    return $caseCount
}

function Assert-DependencyReview {
    param(
        [string] $Workflow
    )

    $review = Get-WorkflowJob $Workflow 'dependency-review'
    Assert-Policy ($review -match 'fail-on-severity: high\s') 'Reject new high/critical dependency advisories.'
    Assert-Policy ($review -match 'fail-on-scopes: runtime, development, unknown') 'Include build/test and unknown dependency scopes.'
    Assert-Policy ($review -match 'warn-only: false') 'Dependency Review must fail on findings.'
    Assert-Policy ($Workflow -notmatch 'contents: write|pull-requests: write|continue-on-error:') 'Security checks need no write token or ignored failures.'
}

function Assert-NugetAuditJob {
    param(
        [string] $Workflow
    )

    $job = Get-WorkflowJob $Workflow 'nuget-audit'
    Assert-Policy ($job -notmatch '(?m)^    if:') 'Audit the resolved graph on PRs, main and schedule.'
    Assert-Policy ($job -match 'global-json-file: global.json') 'Use the repository SDK for all target frameworks.'
    Assert-Policy ($job -match './scripts/security/Test-NuGetDependencies.ps1') 'Run the same audit locally and in CI.'
    Assert-Policy ($job -match 'persist-credentials: false') 'The audit does not need persisted checkout credentials.'
}

function Assert-AuditDefaults {
    param(
        [object[]] $Arguments,
        [string] $Root
    )

    $solution = [IO.Path]::GetFullPath($Arguments[1])
    $expectedSolution = [IO.Path]::GetFullPath((Join-Path $Root 'grate.slnx'))
    Assert-Policy ($solution -eq $expectedSolution) 'Audit the maintained SLNX solution by default.'

    $configIndex = [array]::IndexOf($Arguments, '--configfile')
    Assert-Policy ($configIndex -ge 0) 'Pass an explicit shared NuGet configuration.'
    $config = [IO.Path]::GetFullPath($Arguments[$configIndex + 1])
    $expectedConfig = [IO.Path]::GetFullPath((Join-Path $Root 'NuGet.Config'))
    Assert-Policy ($config -eq $expectedConfig) 'Reuse the shared root NuGet configuration.'
}

function Assert-AuditCommand {
    param(
        [string] $Root
    )

    # Capture command arguments in this private closure. Only LASTEXITCODE uses
    # the native-command convention; restore its previous value during cleanup.
    $auditState = @{
        Arguments = @()
        ExitCode = 0
    }
    $previousExitCode = $global:LASTEXITCODE
    $dotnetStub = {
        $auditState.Arguments = @($args)
        $global:LASTEXITCODE = $auditState.ExitCode
    }.GetNewClosure()
    Set-Item -Path Function:local:dotnet -Value $dotnetStub

    try {
        $auditScript = Join-Path $Root 'scripts/security/Test-NuGetDependencies.ps1'
        & $auditScript
        Assert-AuditDefaults -Arguments $auditState.Arguments -Root $Root

        & $auditScript -Project 'fixture.csproj'
        $expectedArguments = @(
            'restore',
            'fixture.csproj',
            '--configfile',
            '--force-evaluate',
            '-p:NuGetAudit=true',
            '-p:NuGetAuditMode=all',
            '-p:NuGetAuditLevel=low',
            '-p:TreatWarningsAsErrors=true',
            '-p:WarningsNotAsErrors=NU1901%3BNU1902'
        )
        foreach ($argument in $expectedArguments) {
            Assert-Policy ($argument -in $auditState.Arguments) "Missing audit argument: $argument"
        }

        foreach ($exitCode in @(1, 42)) {
            $auditState.ExitCode = $exitCode
            $rejected = $false
            try {
                & $auditScript -Project 'fixture.csproj'
            }
            catch {
                $rejected = $_ -match 'NuGet dependency audit failed'
            }
            Assert-Policy $rejected "Propagate failed restore/feed audit exit code $exitCode."
        }
    }
    finally {
        Remove-Item -LiteralPath Function:local:dotnet
        $global:LASTEXITCODE = $previousExitCode
    }
}

function Assert-AuditMockIsolation {
    param(
        [string] $Root
    )

    function dotnet {
        throw 'Audit checks must use their own local stub.'
    }

    $outerFunction = Get-Item -LiteralPath Function:local:dotnet
    $previousExitCode = $global:LASTEXITCODE
    Assert-AuditCommand $Root
    $remainingFunction = Get-Item -LiteralPath Function:local:dotnet -ErrorAction SilentlyContinue
    Assert-Policy ($remainingFunction.ScriptBlock -eq $outerFunction.ScriptBlock) 'Audit checks must preserve an existing caller dotnet wrapper.'
    Assert-Policy ($global:LASTEXITCODE -eq $previousExitCode) 'Audit checks must restore the caller exit code.'
}

function Assert-AuditFeed {
    param(
        [string] $Root
    )

    [xml] $config = Get-Content -LiteralPath (Join-Path $Root 'NuGet.Config') -Raw
    $auditSource = $config.configuration.auditSources.add.value
    Assert-Policy ($auditSource -eq 'https://api.nuget.org/v3/index.json') 'Use the explicit shared vulnerability feed so missing data is not silently ignored.'
}

$ci = Get-Content -LiteralPath (Join-Path $RepositoryRoot '.github/workflows/ci.yml') -Raw
$dependencies = Get-Content -LiteralPath (Join-Path $RepositoryRoot '.github/workflows/dependency-security.yml') -Raw
Assert-SecurityTriggers $ci
Assert-SecurityTriggers $dependencies
Assert-CodeqlExtraction (Get-WorkflowJob $ci 'analyze')
Assert-StagedCiJobs $ci
$schedulingCases = Assert-CodeqlScheduling (Get-WorkflowJob $ci 'analyze')
Assert-DependencyReview $dependencies
Assert-NugetAuditJob $dependencies
Assert-AuditMockIsolation $RepositoryRoot
Assert-AuditFeed $RepositoryRoot
Write-Host "Dependency security policy, $schedulingCases scheduling cases and audit command checks passed."
