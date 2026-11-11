#!/usr/bin/env pwsh
param(
    [string]$SupervisorPath = (Join-Path $PSScriptRoot 'support/Invoke-MsiLifecycle.ps1'),
    [ValidateSet('Success', 'NativeFailure', 'ScriptFailure', 'ScriptFailureNull', 'ScriptFailureStaleNonzero', 'WorkerHang', 'DescendantSuccess', 'DescendantTimeout')]
    [string[]]$Cases = @('Success', 'NativeFailure', 'ScriptFailure', 'ScriptFailureNull', 'ScriptFailureStaleNonzero', 'WorkerHang', 'DescendantSuccess', 'DescendantTimeout')
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '../InstallerLifecycle.Diagnostics.ps1')
$directory = Join-Path $env:RUNNER_TEMP ('lifecycle/supervisor contract evidence/' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $directory -Force | Out-Null
$result = @{
    Succeeded = $false
    Cases = @()
    StartupFailures = @()
    CleanupFailures = @()
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
if ($Mode -eq 'ScriptFailureStaleNonzero') {
    $global:LASTEXITCODE = 37
    throw 'Synthetic worker failure after an unrelated native exit'
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
    $runnerExecutable = Join-Path $PSHOME 'pwsh.exe'
    if ($Mode -like 'StartupFailure*') {
        # These are the two valid BeforeStart record shapes when native launch
        # fails. The executable is genuinely absent; Process.Start is not mocked.
        New-Item -ItemType Directory -Path "$output-supervisor" | Out-Null
        $startupRecord = @{ Phase = 'BeforeStart' }
        if ($Mode -eq 'StartupFailureNullPid') {
            $startupRecord.ProcessId = $null
        }
        $startupRecord | ConvertTo-Json | Set-Content -LiteralPath "$output-supervisor/process.json"
        $runnerExecutable = Join-Path $directory 'nonexistent-supervisor-runner.exe'
    }
    $start = [Diagnostics.ProcessStartInfo]::new($runnerExecutable)
    $start.UseShellExecute = $false
    foreach ($argument in @('-NoLogo', '-NoProfile', '-NonInteractive', '-File', $runner, '-Settings', $caseSettings)) {
        $start.ArgumentList.Add($argument)
    }
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $start
    $watch = [Diagnostics.Stopwatch]::StartNew()
    $primaryFailure = $null
    $runnerStarted = $false
    try {
        [void]$process.Start()
        $runnerStarted = $true
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
        if ($Mode -like 'Descendant*') {
            $descendantId = $null
            $descendant = $null
            if (Test-Path -LiteralPath "$output/descendant.pid") {
                $descendantId = [int](Get-Content -LiteralPath "$output/descendant.pid")
                $descendant = Get-Process -Id $descendantId -ErrorAction SilentlyContinue
            }
            $triggerObservation = @{
                Utc = [DateTime]::UtcNow.ToString('o')
                Mode = $Mode
                ElapsedSeconds = $watch.Elapsed.TotalSeconds
                WorkerEntered = (Test-Path -LiteralPath "$output/entered.txt")
                DescendantReady = (Test-Path -LiteralPath "$output/descendant-ready.txt")
                DescendantPid = $descendantId
                DescendantAlive = ($null -ne $descendant -and !$descendant.HasExited)
                SupervisorExited = $process.HasExited
            }
            $triggerObservation | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $directory "$Mode.trigger.json")
            if (!$triggerObservation.WorkerEntered -or !$triggerObservation.DescendantReady -or
                !$triggerObservation.DescendantAlive -or !$triggerObservation.SupervisorExited) {
                throw "$Mode inherited-handle trigger was not established before capture assertions."
            }
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
            foreach ($stream in @('stdout', 'stderr')) {
                if ((Get-Content -LiteralPath "$output-supervisor/$stream.log" -Raw) -notlike "*Descendant $stream marker*") {
                    throw "Live descendant did not inherit the $stream log handle."
                }
            }
        }
        if ($observation.Phase -ne 'Completed' -or !$observation.CompletedUtc -or $observation.ElapsedSeconds -gt 25) {
            throw "$Mode did not finish disposal and evidence within its whole-operation bound."
        }
        $requiredPhases = @('BeforeStart', 'AfterStart', 'BeforeWait', 'AfterWait')
        if ($ExpectedTimeout) {
            $requiredPhases += @('BeforeKill', 'AfterKill', 'BeforeTerminationWait', 'AfterTerminationWait')
        }
        $requiredPhases += @('BeforeDispose', 'Completed')
        Assert-InstallerLifecyclePhaseOrder -Path "$output-supervisor/phases.jsonl" -RequiredPhases $requiredPhases
        $diagnostics = Get-Content -LiteralPath "$output-supervisor/diagnostics.json" -Raw | ConvertFrom-Json
        if (@($diagnostics.Failures).Count) {
            throw "$Mode retained unexpected diagnostic failures."
        }
        $result.Cases += @{
            Mode = $Mode
            ExitCode = $observation.ExitCode
            TimedOut = $observation.TimedOut
            ElapsedSeconds = $watch.Elapsed.TotalSeconds
        }
    } catch {
        $primaryFailure = $_.Exception
        throw
    } finally {
        $cleanupFailures = [Collections.Generic.List[Exception]]::new()
        $cleanupObservation = @{
            Mode = $Mode
            RunnerStarted = $runnerStarted
            RunnerExitConfirmed = $false
            RunnerDisposed = $false
            SkippedProcessIds = 0
            OwnedProcesses = @()
        }
        try {
            foreach ($pidFile in @("$output-supervisor/process.json", "$output/descendant.pid")) {
                try {
                    if (!(Test-Path -LiteralPath $pidFile)) {
                        continue
                    }
                    $ownedId = if ($pidFile.EndsWith('.json')) {
                        (Get-Content -LiteralPath $pidFile -Raw | ConvertFrom-Json).ProcessId
                    } else {
                        Get-Content -LiteralPath $pidFile
                    }
                    $parsedId = 0
                    if (![int]::TryParse([string]$ownedId, [ref]$parsedId) -or $parsedId -le 0) {
                        $cleanupObservation.SkippedProcessIds++
                        continue
                    }
                    $owned = $null
                    $ownedCleanup = @{
                        ProcessId = $parsedId
                        PresentAtCleanup = $false
                        KillRequested = $false
                        ExitConfirmed = $false
                        Disposed = $false
                    }
                    try {
                        $owned = Get-Process -Id $parsedId -ErrorAction SilentlyContinue
                        $ownedCleanup.PresentAtCleanup = ($null -ne $owned)
                        if ($null -ne $owned) {
                            if (!$owned.HasExited) {
                                $ownedCleanup.KillRequested = $true
                                $owned.Kill()
                            }
                            if (!$owned.WaitForExit(5000)) {
                                throw "Owned supervisor-test process $parsedId did not terminate within five seconds."
                            }
                        }
                        $ownedCleanup.ExitConfirmed = $true
                    } finally {
                        try {
                            if ($null -ne $owned) {
                                $owned.Dispose()
                                $ownedCleanup.Disposed = $true
                            }
                        } finally {
                            $cleanupObservation.OwnedProcesses += $ownedCleanup
                        }
                    }
                } catch {
                    $cleanupFailures.Add($_.Exception)
                }
            }
        } finally {
            try {
                if ($runnerStarted) {
                    if (!$process.HasExited) {
                        $process.Kill()
                    }
                    if (!$process.WaitForExit(5000)) {
                        throw 'Supervisor-test runner did not terminate within five seconds.'
                    }
                    $cleanupObservation.RunnerExitConfirmed = $true
                }
            } catch {
                $cleanupFailures.Add($_.Exception)
            } finally {
                try {
                    $process.Dispose()
                    $cleanupObservation.RunnerDisposed = $true
                } catch {
                    $cleanupFailures.Add($_.Exception)
                }
            }
        }
        Write-InstallerLifecycleDiagnostic -Path (Join-Path $directory "$Mode.cleanup.json") -Value $cleanupObservation -Failures $cleanupFailures
        $result.CleanupFailures += @($cleanupFailures | ForEach-Object Message)
        if (!$primaryFailure -and $cleanupFailures.Count) {
            throw [AggregateException]::new('Supervisor test cleanup failed.', $cleanupFailures)
        }
    }
}

try {
    foreach ($mode in @('StartupFailureMissingPid', 'StartupFailureNullPid')) {
        $failure = $null
        try {
            Invoke-SupervisorCase $mode 0 $false
        } catch {
            $failure = $_.Exception
        }
        $cause = $failure
        while ($null -ne $cause -and $null -ne $cause.InnerException) {
            $cause = $cause.InnerException
        }
        if ($cause -isnot [ComponentModel.Win32Exception] -or $cause.NativeErrorCode -ne 2) {
            throw 'The original native startup failure was masked by test cleanup.'
        }
        $cleanup = Get-Content -LiteralPath (Join-Path $directory "$mode.cleanup.json") -Raw | ConvertFrom-Json
        if ($cleanup.RunnerStarted -or !$cleanup.RunnerDisposed -or $cleanup.SkippedProcessIds -ne 1) {
            throw 'Startup failure did not dispose the runner and safely ignore its absent/null PID.'
        }
        $result.StartupFailures += $cleanup
    }
    foreach ($case in $Cases) {
        $expectedExit = if ($case -in @('Success', 'DescendantSuccess')) { 0 } else { 1 }
        Invoke-SupervisorCase $case $expectedExit ($case -in @('WorkerHang', 'DescendantTimeout'))
        $cleanup = Get-Content -LiteralPath (Join-Path $directory "$case.cleanup.json") -Raw | ConvertFrom-Json
        if (!$cleanup.RunnerStarted -or !$cleanup.RunnerExitConfirmed -or !$cleanup.RunnerDisposed -or @($cleanup.OwnedProcesses | Where-Object {
                    !$_.ExitConfirmed -or ($_.PresentAtCleanup -and !$_.Disposed)
                }).Count) {
            throw "$case did not confirm termination and disposal of its owned processes."
        }
        if ($case -like 'Descendant*') {
            $descendantId = [int](Get-Content -LiteralPath (Join-Path $directory "$case/descendant.pid"))
            $descendantCleanup = @($cleanup.OwnedProcesses | Where-Object ProcessId -EQ $descendantId)
            if ($descendantCleanup.Count -ne 1 -or !$descendantCleanup[0].KillRequested -or
                !$descendantCleanup[0].ExitConfirmed -or !$descendantCleanup[0].Disposed) {
                throw "$case did not establish bounded termination and disposal of its live descendant."
            }
        }
    }
    $result.Succeeded = $true
    Write-Host 'PASS: success, native failure, timeout and live descendant handles retain evidence and return within the supervisor bound.'
} finally {
    $result | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $directory 'result.json')
}
