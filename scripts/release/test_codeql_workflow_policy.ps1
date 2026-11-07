#!/usr/bin/env pwsh
. "$PSScriptRoot/workflow_test_helpers.ps1"
$job = (Read-Workflow 'ci.yml').jobs.analyze
Assert-Policy ($job.name -ceq 'Analyze Code Security') 'Preserve the CodeQL check name.'
Assert-Policy ($job.'runs-on' -ceq 'windows-latest') 'MSI C++ extraction requires Windows.'
$init = Get-ActionStep $job 'github/codeql-action/init'
$autobuild = Get-ActionStep $job 'github/codeql-action/autobuild'
$analyze = Get-ActionStep $job 'github/codeql-action/analyze'
Assert-Policy ($null -ne $init -and $null -ne $autobuild -and $null -ne $analyze) 'Require CodeQL initialization, autobuild and analysis.'
Assert-Policy (!$init.with -or !$init.with.ContainsKey('languages')) 'Keep language autodetection, including Windows MSI C++.'
$steps = @($job.steps)
Assert-Policy ($steps.IndexOf($init) -lt $steps.IndexOf($autobuild) -and $steps.IndexOf($autobuild) -lt $steps.IndexOf($analyze)) 'Autobuild must run between initialization and analysis.'
$script = 'installers/msi/native/Build-UpgradeActions.ps1'
Assert-Policy (Test-Path -LiteralPath "$repositoryRoot/$script" -PathType Leaf) 'Require actual native MSI build helper.'
$build = $steps | Where-Object { $_.run -clike "*$script*" } | Select-Object -First 1
Assert-Policy ($null -ne $build) 'Extract the actual MSI compiler invocation.'
Assert-Policy ($build.shell -ceq 'pwsh') 'Native MSI build requires PowerShell.'
Assert-Policy ($build.run.Contains('-Architecture x64') -and $build.run.Contains('-OutputDirectory "$env:RUNNER_TEMP/')) 'Preserve architecture and isolated output directory.'
Assert-Policy ($steps.IndexOf($init) -lt $steps.IndexOf($build) -and $steps.IndexOf($build) -lt $steps.IndexOf($analyze)) 'Native compilation must run between CodeQL init and analysis.'
Assert-Policy ($job.permissions.'security-events' -ceq 'write') 'CodeQL must be able to publish analysis.'
Assert-Policy (!$job.ContainsKey('if') -and !$job.'continue-on-error') 'CodeQL job cannot skip or ignore failures.'
foreach ($step in $steps) {
    Assert-Policy (!$step.ContainsKey('if') -and !$step.'continue-on-error' -and $step.run -cnotlike '*|| true*') 'CodeQL steps cannot bypass compilation failures.'
}
$builder = Get-Content -LiteralPath "$repositoryRoot/$script" -Raw
Assert-Policy ($builder.Contains("`$ErrorActionPreference = 'Stop'") -and $builder.Contains('if ($LASTEXITCODE -ne 0')) 'Native compiler failures must reach the caller.'
Write-Host 'PASS: CodeQL runner, extraction order and failure propagation.'
