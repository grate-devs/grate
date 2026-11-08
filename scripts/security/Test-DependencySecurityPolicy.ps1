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

function Get-Job {
    param(
        [string] $Workflow,
        [string] $Id
    )
    $match = [regex]::Match($Workflow, "(?ms)^  ${Id}:\r?\n(?<body>.*?)(?=^  [\w-]+:|\z)")
    Assert-Policy $match.Success "Missing job: $Id"
    return $match.Groups['body'].Value
}

$ci = Get-Content -LiteralPath (Join-Path $RepositoryRoot '.github/workflows/ci.yml') -Raw
$dependencies = Get-Content -LiteralPath (Join-Path $RepositoryRoot '.github/workflows/dependency-security.yml') -Raw
foreach ($workflow in @($ci, $dependencies)) {
    Assert-Policy ($workflow -match '(?m)^  pull_request:') 'Keep PR analysis enabled.'
    Assert-Policy ($workflow -match '(?m)^  push:') 'Keep main analysis enabled.'
    Assert-Policy ($workflow -match '(?m)^  schedule:') 'Keep periodic analysis enabled.'
    Assert-Policy ($workflow -notmatch '(?m)^  pull_request_target:|^    paths(-ignore)?:') 'Do not filter or privilege security PR checks.'
}

$analysis = Get-Job $ci 'analyze'
Assert-Policy ($analysis -match 'name: Analyze Code Security') 'Preserve the CodeQL check name.'
Assert-Policy ($analysis -match 'runs-on: windows-latest') 'Extract the Windows MSI code on Windows.'
Assert-Policy ($analysis -notmatch 'continue-on-error:') 'Propagate analysis failures.'
Assert-Policy ($analysis -match 'languages: csharp, c-cpp, actions') 'Keep the maintained languages after the Python-to-PowerShell migration.'
$init = $analysis.IndexOf('github/codeql-action/init@')
$managed = $analysis.IndexOf('dotnet build grate.slnx --configuration Release --no-incremental -p:UseSharedCompilation=false')
$native = $analysis.IndexOf('./installers/msi/native/Build-UpgradeActions.ps1 -Architecture x64')
$analyze = $analysis.IndexOf('github/codeql-action/analyze@')
Assert-Policy ($init -ge 0 -and $managed -gt $init -and $native -gt $init -and $analyze -gt $managed -and $analyze -gt $native) 'Trace the full SLNX solution and real native compilation between CodeQL init and analyze.'
foreach ($job in @('build-code', 'fast-tests', 'test', 'packages', 'standalone', 'docker')) {
    $body = Get-Job $ci $job
    Assert-Policy ($body -notmatch '(?m)^    if:|continue-on-error:') "Preserve the staged success-only gate for $job."
    Assert-Policy ($body -match '(?m)^    needs:') "Keep $job downstream of PR-only preflight."
}
foreach ($job in @('validation-policy', 'report', 'ci-result')) {
    Assert-Policy ((Get-Job $ci $job) -match "if: .*github.event_name == 'pull_request'.*github.event_name == 'workflow_dispatch'") "Keep $job limited to PR/manual validation."
}
Assert-Policy ((Get-Job $ci 'report') -match 'if: always\(\) &&') 'Retain failure reporting for PR/manual tests.'

# Evaluate the actual GitHub condition against an independent scheduling table.
# Missing/skipped/failed prerequisites must reject PR/manual runs, while baseline
# analysis on main/schedule must survive the intentionally skipped PR-only jobs.
$conditionMatch = [regex]::Match($analysis, '(?m)^    if: \$\{\{ (.+) \}\}\r?$')
Assert-Policy $conditionMatch.Success 'Require an explicit event-aware CodeQL gate.'
$condition = $conditionMatch.Groups[1].Value
Assert-Policy ($condition.Contains('always()')) 'CodeQL baseline must run after skipped prerequisites.'
$expression = $condition.Replace('always()', '$true').Replace('github.event_name', '$EventName')
$expression = $expression.Replace('needs.build-code.result', '$BuildResult').Replace('needs.fast-tests.result', '$FastResult').Replace('needs.validation-policy.result', '$PolicyResult')
$expression = $expression.Replace('&&', '-and').Replace('||', '-or').Replace('==', '-ceq')
$evaluateCondition = [scriptblock]::Create('param($EventName, $BuildResult, $FastResult, $PolicyResult) ' + $expression)
$schedulingCases = 0
foreach ($eventName in @('push', 'schedule', 'pull_request', 'workflow_dispatch', 'workflow_run')) {
    foreach ($buildResult in @('success', 'failure', 'cancelled', 'skipped', $null)) {
        foreach ($fastResult in @('success', 'failure', 'cancelled', 'skipped', $null)) {
            foreach ($policyResult in @('success', 'failure', 'cancelled', 'skipped', $null)) {
                $expected = $eventName -in @('push', 'schedule') -or (
                    $eventName -in @('pull_request', 'workflow_dispatch') -and
                    $buildResult -eq 'success' -and $fastResult -eq 'success' -and $policyResult -eq 'success'
                )
                $actual = [bool] (& $evaluateCondition $eventName $buildResult $fastResult $policyResult)
                Assert-Policy ($actual -eq $expected) "Incorrect CodeQL scheduling for $eventName/$buildResult/$fastResult/$policyResult."
                $schedulingCases++
            }
        }
    }
}

$review = Get-Job $dependencies 'dependency-review'
Assert-Policy ($review -match 'fail-on-severity: high\s') 'Reject new high/critical dependency advisories.'
Assert-Policy ($review -match 'fail-on-scopes: runtime, development, unknown') 'Include build/test and unknown dependency scopes.'
Assert-Policy ($review -match 'warn-only: false') 'Dependency Review must fail on findings.'
Assert-Policy ($dependencies -notmatch 'contents: write|pull-requests: write|continue-on-error:') 'Security checks need no write token or ignored failures.'
$audit = Get-Job $dependencies 'nuget-audit'
Assert-Policy ($audit -notmatch '(?m)^    if:') 'Audit the resolved graph on PRs, main and schedule.'
Assert-Policy ($audit -match 'global-json-file: global.json') 'Use the repository SDK for all target frameworks.'
Assert-Policy ($audit -match './scripts/security/Test-NuGetDependencies.ps1') 'Run the same audit locally and in CI.'

# Exercise the command contract and failure propagation without contacting feeds.
$global:GrateAuditTestState = @{
    Arguments = @()
    ExitCode = 0
}
function dotnet {
    $global:GrateAuditTestState.Arguments = $args
    $global:LASTEXITCODE = $global:GrateAuditTestState.ExitCode
}
try {
    $auditScript = Join-Path $RepositoryRoot 'scripts/security/Test-NuGetDependencies.ps1'
    & $auditScript
    $defaultSolution = [IO.Path]::GetFullPath($global:GrateAuditTestState.Arguments[1])
    Assert-Policy ($defaultSolution -eq [IO.Path]::GetFullPath((Join-Path $RepositoryRoot 'grate.slnx'))) 'Audit the maintained SLNX solution by default.'
    $configIndex = [array]::IndexOf($global:GrateAuditTestState.Arguments, '--configfile')
    $configPath = [IO.Path]::GetFullPath($global:GrateAuditTestState.Arguments[$configIndex + 1])
    Assert-Policy ($configPath -eq [IO.Path]::GetFullPath((Join-Path $RepositoryRoot 'NuGet.Config'))) 'Reuse the shared root NuGet configuration.'
    & $auditScript -Project 'fixture.csproj'
    foreach ($expected in @('restore', 'fixture.csproj', '--configfile', '--force-evaluate', '-p:NuGetAudit=true', '-p:NuGetAuditMode=all', '-p:NuGetAuditLevel=low', '-p:TreatWarningsAsErrors=true', '-p:WarningsNotAsErrors=NU1901%3BNU1902')) {
        Assert-Policy ($expected -in $global:GrateAuditTestState.Arguments) "Missing audit argument: $expected"
    }
    foreach ($exitCode in @(1, 42)) {
        $global:GrateAuditTestState.ExitCode = $exitCode
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
    Remove-Item Function:dotnet
    Remove-Variable GrateAuditTestState -Scope Global
    $global:LASTEXITCODE = 0
}

[xml] $config = Get-Content -LiteralPath (Join-Path $RepositoryRoot 'NuGet.Config') -Raw
Assert-Policy ($config.configuration.auditSources.add.value -eq 'https://api.nuget.org/v3/index.json') 'Use the explicit shared vulnerability feed so missing data is not silently ignored.'
Write-Host "Dependency security policy, $schedulingCases scheduling cases and audit command checks passed."
