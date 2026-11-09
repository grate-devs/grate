#!/usr/bin/env pwsh
. "$PSScriptRoot/workflow_test_helpers.ps1"

function Assert-DockerPolicyDependencies {
    param(
        [string]$Commands
    )

    $lines = @($Commands -split '\r?\n' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    $installPosition = [Array]::IndexOf($lines, './scripts/release/Install-TestDependencies.ps1')
    $testCommands = @(
        './scripts/release/Run-Tests.ps1 -Path installers/docker/tests'
        './scripts/release/Run-Tests.ps1 -Filter ''test_*docker*.ps1'''
    )
    foreach ($testCommand in $testCommands) {
        $testPosition = [Array]::IndexOf($lines, $testCommand)
        Assert-Policy ($installPosition -ge 0 -and $testPosition -gt $installPosition) 'Install Docker policy dependencies before both test suites.'
    }
}

$publisher = (Read-Workflow 'build.yml').jobs['publish-docker']
$policy = @($publisher.steps | Where-Object { $_['name'] -ceq 'Check Docker release policy' })
Assert-Policy ($policy.Count -eq 1 -and $policy[0].shell -ceq 'pwsh') 'Require one PowerShell Docker policy step.'
Assert-DockerPolicyDependencies -Commands $policy[0].run

$missingInstaller = $policy[0].run.Replace('./scripts/release/Install-TestDependencies.ps1', '')
$lateInstaller = @'
./scripts/release/Run-Tests.ps1 -Path installers/docker/tests
./scripts/release/Install-TestDependencies.ps1
./scripts/release/Run-Tests.ps1 -Filter 'test_*docker*.ps1'
'@
foreach ($incorrect in @($missingInstaller, $lateInstaller)) {
    $rejected = $false
    try {
        Assert-DockerPolicyDependencies -Commands $incorrect
    } catch {
        if ($_.Exception.Message -cne 'Install Docker policy dependencies before both test suites.') {
            throw
        }
        $rejected = $true
    }
    Assert-Policy $rejected 'Missing or late Docker dependency installation must fail policy validation.'
}
Write-Host 'PASS: Docker policy dependency bootstrap and two missing/late installation regressions.'
