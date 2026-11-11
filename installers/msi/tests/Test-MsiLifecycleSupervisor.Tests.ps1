#!/usr/bin/env pwsh
param(
    [string]$SupervisorPath = (Join-Path $PSScriptRoot 'support/Invoke-MsiLifecycle.ps1'),
    [ValidateSet('Success', 'NativeFailure', 'ScriptFailure', 'ScriptFailureNull', 'WorkerHang', 'DescendantSuccess', 'DescendantTimeout')]
    [string[]]$Cases = @('Success', 'NativeFailure', 'ScriptFailure', 'ScriptFailureNull', 'WorkerHang', 'DescendantSuccess', 'DescendantTimeout')
)

$ErrorActionPreference = 'Stop'
$directory = Join-Path $env:RUNNER_TEMP ('lifecycle/supervisor contract evidence/' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $directory -Force | Out-Null
$result = @{
    Succeeded = $false
    Cases = @()
}
$workerScript = Join-Path $directory 'worker-test.ps1'
@'
param(
    [string]$OutputDirectory,
    [string]$Mode
)
New-Item -ItemType Directory -Path $OutputDirectory | Out-Null
'Worker entered' | Set-Content -LiteralPath (Join-Path $OutputDirectory 'entered.txt')
Write-Output 'Retained PowerShell stdout marker'
[Console]::Out.WriteLine('Retained native stdout marker')
[Console]::Error.WriteLine('Retained native stderr marker')
if ($Mode -like 'Descendant*') {
    $childScript = Join-Path $OutputDirectory 'descendant.ps1'
    @"
[Console]::Out.WriteLine('Descendant stdout marker')
[Console]::Error.WriteLine('Descendant stderr marker')
Set-Content -LiteralPath '$OutputDirectory/descendant-ready.txt' -Value 'Ready'
[Threading.Thread]::Sleep(60000)
"@ | Set-Content -LiteralPath $childScript
    $start = [Diagnostics.ProcessStartInfo]::new((Join-Path $PSHOME 'pwsh.exe'))
    $start.UseShellExecute = $false
    foreach ($argument in @('-NoLogo', '-NoProfile', '-NonInteractive', '-File', $childScript)) {
        $start.ArgumentList.Add($argument)
    }
    $child = [Diagnostics.Process]::Start($start)
    $child.Id | Set-Content -LiteralPath (Join-Path $OutputDirectory 'descendant.pid')
    $ready = Join-Path $OutputDirectory 'descendant-ready.txt'
    $watch = [Diagnostics.Stopwatch]::StartNew()
    while (!(Test-Path -LiteralPath $ready)) {
        if ($watch.Elapsed.TotalSeconds -gt 3) {
            throw 'Descendant did not become ready.'
        }
        [Threading.Thread]::Sleep(20)
    }
}
if ($Mode -in @('WorkerHang', 'DescendantTimeout')) {
    [Threading.Thread]::Sleep(60000)
}
if ($Mode -eq 'NativeFailure') {
    exit 37
}
if ($Mode -eq 'ScriptFailure') {
    $global:LASTEXITCODE = 0
    throw 'Synthetic worker failure'
}
if ($Mode -eq 'ScriptFailureNull') {
    Remove-Variable -Name LASTEXITCODE -Scope Global -ErrorAction SilentlyContinue
    throw 'Synthetic worker failure without a native exit code'
}
Write-Output 'Worker completed'
'@ | Set-Content -LiteralPath $workerScript

function Invoke-SupervisorCase {
    param(
        [string]$Mode,
        [int]$ExpectedExitCode,
        [bool]$ExpectedTimeout
    )
    $output = Join-Path $directory $Mode
    $caseSettings = Join-Path $directory "$Mode.settings.json"
    @{
        Supervisor = (Resolve-Path -LiteralPath $SupervisorPath).Path
        Script = $workerScript
        Output = $output
        Mode = $Mode
    } | ConvertTo-Json | Set-Content -LiteralPath $caseSettings
    $runner = Join-Path $directory "$Mode.runner.ps1"
    @'
param([string]$Settings)
$ErrorActionPreference = 'Stop'
$case = Get-Content -LiteralPath $Settings -Raw | ConvertFrom-Json
try {
    & $case.Supervisor -ScriptPath $case.Script -TimeoutSeconds 5 -Parameters @{
        OutputDirectory = $case.Output
        Mode = $case.Mode
    }
} catch {
    $_.Exception.Message | Set-Content -LiteralPath ($case.Output + '.failure.txt')
    exit 1
}
'@ | Set-Content -LiteralPath $runner
    $start = [Diagnostics.ProcessStartInfo]::new((Join-Path $PSHOME 'pwsh.exe'))
    $start.UseShellExecute = $false
    foreach ($argument in @('-NoLogo', '-NoProfile', '-NonInteractive', '-File', $runner, '-Settings', $caseSettings)) {
        $start.ArgumentList.Add($argument)
    }
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $start
    $watch = [Diagnostics.Stopwatch]::StartNew()
    try {
        [void]$process.Start()
        # Independent watchdog: old supervisors must fail this assertion rather
        # than block the test on descendant-held pipes or Process.Dispose.
        if (!$process.WaitForExit(25000)) {
            $descendantId = $null
            $descendant = $null
            if (Test-Path -LiteralPath "$output/descendant.pid") {
                $descendantId = [int](Get-Content -LiteralPath "$output/descendant.pid")
                $descendant = Get-Process -Id $descendantId -ErrorAction SilentlyContinue
            }
            $watchdogObservation = @{
                Utc = [DateTime]::UtcNow.ToString('o')
                Mode = $Mode
                WorkerEntered = (Test-Path -LiteralPath "$output/entered.txt")
                DescendantReady = (Test-Path -LiteralPath "$output/descendant-ready.txt")
                DescendantPid = $descendantId
                DescendantAlive = ($null -ne $descendant -and !$descendant.HasExited)
                SupervisorAlive = !$process.HasExited
            }
            $watchdogObservation | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $directory "$Mode.watchdog.json")
            $process.Kill()
            [void]$process.WaitForExit(1000)
            if ($Mode -like 'Descendant*' -and (!$watchdogObservation.WorkerEntered -or
                    !$watchdogObservation.DescendantReady -or !$watchdogObservation.DescendantAlive -or
                    !$watchdogObservation.SupervisorAlive)) {
                throw "$Mode inherited-handle trigger was not established before watchdog expiry."
            }
            throw "$Mode supervisor did not return within its whole-operation bound."
        }
        $observation = Get-Content -LiteralPath "$output-supervisor/process.json" -Raw | ConvertFrom-Json
        if ($process.ExitCode -ne $ExpectedExitCode -or $observation.TimedOut -ne $ExpectedTimeout) {
            throw "$Mode supervisor returned the wrong exit/timeout outcome."
        }
        if ($Mode -eq 'NativeFailure' -and $observation.ExitCode -ne 37) {
            throw 'Native failure exit code was not retained.'
        }
        if ($Mode -like 'ScriptFailure*' -and $observation.ExitCode -ne 1) {
            throw 'PowerShell failure was confused with a missing or stale native exit code.'
        }
        if (!(Test-Path -LiteralPath "$output/entered.txt")) {
            throw "$Mode worker did not enter; this is a setup failure."
        }
        foreach ($stream in @('stdout', 'stderr')) {
            $log = Get-Content -LiteralPath "$output-supervisor/$stream.log" -Raw
            if ($log -notlike "*Retained native $stream marker*") {
                throw "$Mode did not retain partial native $stream evidence."
            }
        }
        if ((Get-Content -LiteralPath "$output-supervisor/stdout.log" -Raw) -notlike '*Retained PowerShell stdout marker*') {
            throw "$Mode did not retain PowerShell output."
        }
        if ($Mode -like 'Descendant*') {
            if (!(Test-Path -LiteralPath "$output/descendant-ready.txt")) {
                throw 'The inherited-handle trigger was not established.'
            }
            $descendant = Get-Process -Id ([int](Get-Content -LiteralPath "$output/descendant.pid")) -ErrorAction SilentlyContinue
            if (!$descendant -or $descendant.HasExited) {
                throw 'Descendant exited before the bounded-return assertion.'
            }
            foreach ($stream in @('stdout', 'stderr')) {
                if ((Get-Content -LiteralPath "$output-supervisor/$stream.log" -Raw) -notlike "*Descendant $stream marker*") {
                    throw "Live descendant did not inherit the $stream log handle."
                }
            }
        }
        if ($observation.Phase -ne 'Completed' -or !$observation.CompletedUtc -or $observation.ElapsedSeconds -gt 25) {
            throw "$Mode did not finish disposal and evidence within its whole-operation bound."
        }
        $result.Cases += @{
            Mode = $Mode
            ExitCode = $observation.ExitCode
            TimedOut = $observation.TimedOut
            ElapsedSeconds = $watch.Elapsed.TotalSeconds
        }
    } finally {
        foreach ($pidFile in @("$output-supervisor/process.json", "$output/descendant.pid")) {
            if (Test-Path -LiteralPath $pidFile) {
                $ownedId = if ($pidFile.EndsWith('.json')) {
                    (Get-Content -LiteralPath $pidFile -Raw | ConvertFrom-Json).ProcessId
                } else {
                    [int](Get-Content -LiteralPath $pidFile)
                }
                $owned = Get-Process -Id $ownedId -ErrorAction SilentlyContinue
                if ($owned -and !$owned.HasExited) {
                    $owned.Kill()
                }
            }
        }
        $process.Dispose()
    }
}

try {
    foreach ($case in $Cases) {
        $expectedExit = if ($case -in @('Success', 'DescendantSuccess')) { 0 } else { 1 }
        Invoke-SupervisorCase $case $expectedExit ($case -in @('WorkerHang', 'DescendantTimeout'))
    }
    $result.Succeeded = $true
    Write-Host 'PASS: success, native failure, timeout and live descendant handles retain evidence and return within the supervisor bound.'
} finally {
    $result | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $directory 'result.json')
}
