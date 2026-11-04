#!/usr/bin/env pwsh
$ErrorActionPreference='Stop'
$directory=Join-Path $env:RUNNER_TEMP ('lifecycle/supervisor-contract/'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $directory -Force | Out-Null
$result=@{Succeeded=$false}
try {
    $script=Join-Path $directory 'worker-test.ps1'
    @'
param([string]$OutputDirectory,[switch]$Block)
New-Item -ItemType Directory -Path $OutputDirectory | Out-Null
'Worker entered' | Set-Content (Join-Path $OutputDirectory 'entered.txt')
if ($Block) { [Threading.Thread]::Sleep(60000) }
'Worker completed'
'@ | Set-Content $script
    & "$PSScriptRoot/support/Invoke-MsiLifecycle.ps1" -ScriptPath $script -TimeoutSeconds 15 -Parameters @{OutputDirectory="$directory/success"}
    $success=Get-Content "$directory/success-supervisor/process.json" -Raw | ConvertFrom-Json
    if ($success.ExitCode -ne 0 -or $success.TimedOut) { throw 'Successful worker was not observed correctly.' }
    $watch=[Diagnostics.Stopwatch]::StartNew()
    $rejected=$false
    try { & "$PSScriptRoot/support/Invoke-MsiLifecycle.ps1" -ScriptPath $script -TimeoutSeconds 5 -Parameters @{OutputDirectory="$directory/blocked";Block=$true} }
    catch { if ($_.Exception.Message -notlike '*exceeded 5 seconds*') { throw }; $rejected=$true }
    $blocked=Get-Content "$directory/blocked-supervisor/process.json" -Raw | ConvertFrom-Json
    if (!$rejected -or !$blocked.TimedOut -or !(Test-Path "$directory/blocked/entered.txt") -or $watch.Elapsed.TotalSeconds -gt 25) { throw 'Blocked worker was not terminated with its partial evidence retained.' }
    $result.Succeeded=$true
    Write-Host 'PASS: child process completion, bounded termination and retained partial evidence.'
} finally { $result | ConvertTo-Json | Set-Content "$directory/result.json" }
