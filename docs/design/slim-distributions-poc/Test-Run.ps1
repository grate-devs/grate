#!/usr/bin/env pwsh
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true
$wrapper = Join-Path $PSScriptRoot 'run.ps1'
$originalLocation = Get-Location
$originalEnvironment = @{}
foreach ($name in @('GRATE_POC_SQLSERVER', 'GRATE_POC_MARIADB')) {
    $originalEnvironment[$name] = [Environment]::GetEnvironmentVariable($name, 'Process')
}

function Assert-True {
    param(
        [bool]$Condition,
        [string]$Message
    )
    if (!$Condition) {
        throw $Message
    }
}

function docker {
    $global:GrateSlimWrapperCalls.Add(@{
        Command = 'docker'
        Arguments = @($args)
    })
    $global:LASTEXITCODE = 0
    if ($args[0] -eq 'ps') {
        'labelled-fixture'
    }
    elseif ($args[0] -eq 'exec' -and $args[1] -like '*-sqlserver') {
        $global:GrateSlimReadinessChecks++
        if ($global:GrateSlimReadinessChecks -eq 1) {
            $global:LASTEXITCODE = 1
        }
    }
    elseif ($args[0] -eq 'exec' -and $args[1] -like '*-sdk' -and $global:GrateSlimFailSdk) {
        # A real failed native process tests the wrapper's original-code handling.
        $shell = (Get-Command pwsh -CommandType Application | Select-Object -First 1).Source
        & $shell -NoProfile -Command 'exit 23'
    }
}

function python3 {
    $global:GrateSlimWrapperCalls.Add(@{
        Command = 'python3'
        Arguments = @($args)
    })
    $global:LASTEXITCODE = 0
}

function Start-Sleep {
    param(
        [int]$Seconds
    )
    Assert-True ($Seconds -eq 2) 'The readiness retry interval changed.'
    $global:GrateSlimDelays++
}

try {
    $env:GRATE_POC_SQLSERVER = 'previous-sqlserver'
    $env:GRATE_POC_MARIADB = 'previous-mariadb'
    foreach ($mode in @('cli', 'packaging')) {
        $global:GrateSlimWrapperCalls = [Collections.Generic.List[object]]::new()
        $global:GrateSlimReadinessChecks = 0
        $global:GrateSlimDelays = 0
        $global:GrateSlimFailSdk = $false
        $output = 'artifacts/fake slim ' + [Guid]::NewGuid().ToString('N')
        & $wrapper -OutputDirectory $output -Mode $mode
        Assert-True ($global:GrateSlimReadinessChecks -eq 2 -and $global:GrateSlimDelays -eq 1) 'Readiness failures must retry before running the verifier.'
        $calls = @($global:GrateSlimWrapperCalls)
        $cleanup = @($calls | Where-Object { $_.Command -eq 'docker' -and $_.Arguments[0] -eq 'rm' })
        Assert-True ($cleanup.Count -eq 2 -and $cleanup[0].Arguments[2] -eq 'labelled-fixture') 'Labelled and named containers must both be cleaned up.'
        Assert-True ($calls[-1].Arguments[0] -eq 'network' -and $calls[-1].Arguments[1] -eq 'rm') 'The dedicated network must be removed last.'
        Assert-True ((Get-Location).Path -ceq $originalLocation.Path) 'The caller location was not restored.'
        Assert-True ($env:GRATE_POC_SQLSERVER -ceq 'previous-sqlserver' -and $env:GRATE_POC_MARIADB -ceq 'previous-mariadb') 'The caller environment was not restored.'
        if ($mode -eq 'cli') {
            $verification = @($calls | Where-Object { $_.Command -eq 'docker' -and $_.Arguments[0] -eq 'exec' -and $_.Arguments[1] -like '*-sdk' })
            Assert-True ($verification.Count -eq 1 -and $verification[0].Arguments[-1] -ceq $output) 'CLI output paths containing spaces must remain one argument.'
            Assert-True ($verification[0].Arguments[4].Contains('verify.py')) 'CLI mode must call its original verifier.'
        }
        else {
            $verification = @($calls | Where-Object { $_.Command -eq 'python3' })
            Assert-True ($verification.Count -eq 1 -and $verification[0].Arguments[2] -ceq $output) 'Packaging output paths containing spaces must remain one argument.'
            Assert-True ($verification[0].Arguments[0] -ceq 'docs/design/slim-distributions-poc/verify-packaging.py') 'Packaging mode must call its original verifier.'
        }
    }

    $global:GrateSlimWrapperCalls = [Collections.Generic.List[object]]::new()
    $global:GrateSlimReadinessChecks = 0
    $global:GrateSlimDelays = 0
    $global:GrateSlimFailSdk = $true
    & $wrapper -OutputDirectory ('artifacts/failed-' + [Guid]::NewGuid().ToString('N')) 2> $null
    Assert-True ($LASTEXITCODE -eq 23) 'The original native failure code must survive cleanup.'
    Assert-True ($global:GrateSlimWrapperCalls[-1].Arguments[1] -eq 'rm') 'Failure must still remove the network.'
    Assert-True ((Get-Location).Path -ceq $originalLocation.Path -and $env:GRATE_POC_SQLSERVER -ceq 'previous-sqlserver') 'Failure must restore caller state.'

    $beforeValidation = $global:GrateSlimWrapperCalls.Count
    $rejected = $false
    try {
        & $wrapper -OutputDirectory $PSScriptRoot
    }
    catch {
        $rejected = $_.Exception.Message -like 'Use a fresh repository-relative*'
    }
    Assert-True ($rejected -and $global:GrateSlimWrapperCalls.Count -eq $beforeValidation) 'Absolute/existing outputs must fail before Docker work.'
    Write-Host 'PASS: CLI/packaging routing, retry, spaced arguments, cleanup, caller-state restoration, validation and native failure propagation.'
}
finally {
    foreach ($name in $originalEnvironment.Keys) {
        [Environment]::SetEnvironmentVariable($name, $originalEnvironment[$name], 'Process')
    }
    foreach ($name in @('GrateSlimWrapperCalls', 'GrateSlimReadinessChecks', 'GrateSlimDelays', 'GrateSlimFailSdk')) {
        Remove-Variable -Name $name -Scope Global -ErrorAction SilentlyContinue
    }
}
