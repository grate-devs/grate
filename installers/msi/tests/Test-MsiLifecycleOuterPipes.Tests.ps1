#!/usr/bin/env pwsh
param(
    [string]$SupervisorPath = (Join-Path $PSScriptRoot 'support/Invoke-MsiLifecycle.ps1'),
    [string]$OutputDirectory = (Join-Path $env:RUNNER_TEMP ('msi-outer-pipes/' + [guid]::NewGuid().ToString('N')))
)

$ErrorActionPreference = 'Stop'
if (!$IsWindows -or $env:GITHUB_ACTIONS -ne 'true' -or $env:RUNNER_ENVIRONMENT -ne 'github-hosted') {
    throw 'Outer-pipe proof requires a disposable GitHub-hosted Windows runner.'
}
$OutputDirectory = [IO.Path]::GetFullPath($OutputDirectory)
New-Item -ItemType Directory -Path $OutputDirectory | Out-Null
$SupervisorPath = (Resolve-Path -LiteralPath $SupervisorPath).Path
$pwsh = (Get-Process -Id $PID).Path
$descendantScript = Join-Path $OutputDirectory 'descendant.ps1'
@'
param([string]$ReadyPath)
[Console]::Out.WriteLine('Descendant native stdout marker')
[Console]::Error.WriteLine('Descendant native stderr marker')
'Ready' | Set-Content -LiteralPath $ReadyPath
[Threading.Thread]::Sleep(60000)
'@ | Set-Content -LiteralPath $descendantScript
$workerScript = Join-Path $OutputDirectory 'worker.ps1'
@'
param([string]$OutputDirectory, [string]$DescendantScript)
$ErrorActionPreference = 'Stop'
New-Item -ItemType Directory -Path $OutputDirectory | Out-Null
[Console]::Out.WriteLine('Worker native stdout marker')
[Console]::Error.WriteLine('Worker native stderr marker')
$start = [Diagnostics.ProcessStartInfo]::new((Get-Process -Id $PID).Path)
$start.UseShellExecute = $false
$ready = Join-Path $OutputDirectory 'descendant-ready.txt'
foreach ($argument in @('-NoLogo', '-NoProfile', '-NonInteractive', '-File', $DescendantScript, '-ReadyPath', $ready)) {
    $start.ArgumentList.Add($argument)
}
$child = [Diagnostics.Process]::Start($start)
$child.Id | Set-Content -LiteralPath (Join-Path $OutputDirectory 'descendant.pid')
$watch = [Diagnostics.Stopwatch]::StartNew()
while (!(Test-Path -LiteralPath $ready)) {
    if ($watch.Elapsed.TotalSeconds -gt 5) {
        throw 'Descendant did not become ready within five seconds.'
    }
    [Threading.Thread]::Sleep(20)
}
if ($child.HasExited) {
    throw 'Descendant exited before the worker finished.'
}
$child.Dispose()
'@ | Set-Content -LiteralPath $workerScript
$outerScript = Join-Path $OutputDirectory 'outer-runner.ps1'
@'
param([string]$Settings)
$ErrorActionPreference = 'Stop'
$case = Get-Content -LiteralPath $Settings -Raw | ConvertFrom-Json
$parameters = @{
    OutputDirectory = $case.PayloadDirectory
    DescendantScript = $case.DescendantScript
}
if ($case.Mode -eq 'Supervisor') {
    & $case.Supervisor -ScriptPath $case.Worker -Parameters $parameters -TimeoutSeconds 10
} else {
    # Control: deliberately inherit outer pipes as standard handles.
    & $case.Worker @parameters
}
[Console]::Out.WriteLine('Outer runner stdout marker')
[Console]::Error.WriteLine('Outer runner stderr marker')
'@ | Set-Content -LiteralPath $outerScript

function Invoke-OuterPipeCase {
    param(
        [string]$Mode
    )

    $directory = Join-Path $OutputDirectory $Mode
    New-Item -ItemType Directory -Path $directory | Out-Null
    $payload = Join-Path $directory 'payload'
    $settings = Join-Path $directory 'settings.json'
    @{
        Mode = $Mode
        PayloadDirectory = $payload
        DescendantScript = $descendantScript
        Supervisor = $SupervisorPath
        Worker = $workerScript
    } | ConvertTo-Json | Set-Content -LiteralPath $settings
    $start = [Diagnostics.ProcessStartInfo]::new($pwsh)
    $start.UseShellExecute = $false
    # Match the outer process configuration used by the Actions runner.
    $start.CreateNoWindow = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    foreach ($argument in @('-NoLogo', '-NoProfile', '-NonInteractive', '-File', $outerScript, '-Settings', $settings)) {
        $start.ArgumentList.Add($argument)
    }
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $start
    $stdout = $null
    $stderr = $null
    $started = $false
    $watch = [Diagnostics.Stopwatch]::StartNew()
    $observation = [ordered]@{
        Mode = $Mode
        Source = $env:GITHUB_SHA
        PowerShell = $PSVersionTable.PSVersion.ToString()
        Architecture = [Runtime.InteropServices.RuntimeInformation]::ProcessArchitecture.ToString()
        StartedUtc = [DateTime]::UtcNow.ToString('o')
        OuterExited = $false
        OuterExitCode = $null
        DescendantReady = $false
        DescendantAliveBeforeCleanup = $false
        DescendantAliveAfterEofWait = $false
        DescendantKillRequested = $false
        DescendantTerminationConfirmed = $false
        StdoutEofAfterDescendantKill = $false
        StderrEofAfterDescendantKill = $false
        SetupVerified = $false
        StdoutEofWithinThreeSeconds = $false
        StderrEofWithinThreeSeconds = $false
        Failure = $null
        CleanupFailures = @()
    }
    try {
        [void]$process.Start()
        $started = $true
        $observation.OuterProcessId = $process.Id
        # Begin both reads before waiting for the outer runner to exit.
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        $observation.OuterExited = $process.WaitForExit(15000)
        if (!$observation.OuterExited) {
            throw 'Outer runner did not exit within fifteen seconds; this is not an EOF proof.'
        }
        $observation.OuterExitCode = $process.ExitCode
        if ($process.ExitCode -ne 0) {
            throw 'Outer runner failed before EOF verification; inspect retained native logs.'
        }
        $observation.DescendantReady = Test-Path -LiteralPath "$payload/descendant-ready.txt"
        $descendantId = [int](Get-Content -LiteralPath "$payload/descendant.pid")
        $observation.DescendantProcessId = $descendantId
        $descendant = Get-Process -Id $descendantId -ErrorAction SilentlyContinue
        try {
            $observation.DescendantAliveBeforeCleanup = ($null -ne $descendant -and !$descendant.HasExited)
        } finally {
            if ($null -ne $descendant) {
                $descendant.Dispose()
            }
        }
        if (!$observation.DescendantReady -or !$observation.DescendantAliveBeforeCleanup) {
            throw 'Live descendant trigger was not established before EOF verification.'
        }
        if ($Mode -eq 'Supervisor') {
            foreach ($stream in @('stdout', 'stderr')) {
                $text = Get-Content -LiteralPath "$payload-supervisor/$stream.log" -Raw
                if (!$text.Contains("Worker native $stream marker") -or !$text.Contains("Descendant native $stream marker")) {
                    throw "Supervisor did not retain worker and live descendant native $stream markers."
                }
            }
        }
        $observation.SetupVerified = $true
        try {
            [void][Threading.Tasks.Task]::WhenAll([Threading.Tasks.Task[]]@($stdout, $stderr)).WaitAsync(
                [TimeSpan]::FromSeconds(3)).GetAwaiter().GetResult()
        } catch {
            if ($stdout.IsFaulted -or $stderr.IsFaulted -or $stdout.IsCanceled -or $stderr.IsCanceled) {
                throw 'Outer pipe read failed; this is not an inherited-handle EOF timeout.'
            }
        }
        $observation.StdoutEofWithinThreeSeconds = $stdout.IsCompletedSuccessfully
        $observation.StderrEofWithinThreeSeconds = $stderr.IsCompletedSuccessfully
        $descendant = Get-Process -Id $descendantId -ErrorAction SilentlyContinue
        try {
            $observation.DescendantAliveAfterEofWait = ($null -ne $descendant -and !$descendant.HasExited)
        } finally {
            if ($null -ne $descendant) {
                $descendant.Dispose()
            }
        }
        if (!$observation.DescendantAliveAfterEofWait) {
            throw 'Descendant exited during EOF verification; this is not a live-handle proof.'
        }
        if (!$observation.StdoutEofWithinThreeSeconds -or !$observation.StderrEofWithinThreeSeconds) {
            throw 'Outer stdout/stderr EOF exceeded three seconds while the descendant remained alive.'
        }
    } catch {
        $observation.Failure = $_.Exception.Message
    } finally {
        # Capture the trigger and EOF outcome before terminating any owned PID.
        $observation.ElapsedBeforeCleanupSeconds = $watch.Elapsed.TotalSeconds
        try {
            $observation | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath "$directory/before-cleanup.json"
        } catch {
            $observation.CleanupFailures += $_.Exception.Message
        }
        $ownedIds = @()
        foreach ($path in @("$payload/descendant.pid", "$payload-supervisor/process.json")) {
            try {
                if (Test-Path -LiteralPath $path) {
                    $value = if ($path.EndsWith('.json')) {
                        (Get-Content -LiteralPath $path -Raw | ConvertFrom-Json).ProcessId
                    } else {
                        Get-Content -LiteralPath $path
                    }
                    $parsed = 0
                    if ([int]::TryParse([string]$value, [ref]$parsed) -and $parsed -gt 0) {
                        $ownedIds += $parsed
                    }
                }
            } catch {
                $observation.CleanupFailures += $_.Exception.Message
            }
        }
        if ($started) {
            $ownedIds += $process.Id
        }
        foreach ($ownedId in $ownedIds) {
            $owned = $null
            try {
                $owned = Get-Process -Id $ownedId -ErrorAction SilentlyContinue
                if ($null -ne $owned) {
                    if (!$owned.HasExited) {
                        if ($ownedId -eq $observation.DescendantProcessId) {
                            $observation.DescendantKillRequested = $true
                        }
                        $owned.Kill()
                    }
                    if (!$owned.WaitForExit(5000)) {
                        throw "Owned probe process $ownedId did not terminate within five seconds."
                    }
                    if ($ownedId -eq $observation.DescendantProcessId) {
                        $observation.DescendantTerminationConfirmed = $true
                    }
                }
            } catch {
                $observation.CleanupFailures += $_.Exception.Message
            } finally {
                if ($null -ne $owned) {
                    try {
                        $owned.Dispose()
                    } catch {
                        $observation.CleanupFailures += $_.Exception.Message
                    }
                }
            }
            if ($ownedId -eq $observation.DescendantProcessId -and $null -ne $stdout) {
                # Check EOF immediately after the descendant is stopped, before
                # touching the worker/outer PIDs: this is the causal control.
                try {
                    [void][Threading.Tasks.Task]::WhenAll([Threading.Tasks.Task[]]@($stdout, $stderr)).WaitAsync(
                        [TimeSpan]::FromSeconds(3)).GetAwaiter().GetResult()
                } catch {
                    # Final cleanup still stops every other owned PID and
                    # bounds final drains when this observation is negative.
                }
                $observation.StdoutEofAfterDescendantKill = $stdout.IsCompletedSuccessfully
                $observation.StderrEofAfterDescendantKill = $stderr.IsCompletedSuccessfully
            }
        }
        $readersCompleted = ($null -eq $stdout)
        if ($null -ne $stdout) {
            try {
                [void][Threading.Tasks.Task]::WhenAll([Threading.Tasks.Task[]]@($stdout, $stderr)).WaitAsync(
                    [TimeSpan]::FromSeconds(3)).GetAwaiter().GetResult()
            } catch {
                $observation.CleanupFailures += 'Outer reads did not finish after owned process cleanup.'
            }
            $readersCompleted = $stdout.IsCompleted -and $stderr.IsCompleted
            foreach ($stream in @(@{ Name = 'stdout'; Task = $stdout }, @{ Name = 'stderr'; Task = $stderr })) {
                if ($stream.Task.IsCompletedSuccessfully) {
                    $stream.Task.GetAwaiter().GetResult() | Set-Content -LiteralPath "$directory/outer.$($stream.Name).log"
                }
            }
        }
        # Never reproduce an unbounded pipe-reader Dispose in the probe itself.
        if ($readersCompleted) {
            try {
                $process.Dispose()
            } catch {
                $observation.CleanupFailures += $_.Exception.Message
            }
        }
        $observation.ReadersCompletedAfterCleanup = $readersCompleted
        $observation.CompletedUtc = [DateTime]::UtcNow.ToString('o')
        $observation | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath "$directory/result.json"
    }
    return [pscustomobject]$observation
}

$reports = @()
foreach ($mode in @('Supervisor', 'InheritedPipeControl')) {
    $reports += Invoke-OuterPipeCase $mode
}
$reports | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $OutputDirectory 'summary.json')
foreach ($mode in @('InheritedPipeControl', 'Supervisor')) {
    $report = $reports | Where-Object Mode -EQ $mode
    if (@($report.CleanupFailures).Count -or !$report.ReadersCompletedAfterCleanup) {
        throw 'Outer-pipe proof cleanup failed; do not interpret this as causal evidence.'
    }
    if ($report.Mode -eq 'InheritedPipeControl') {
        if (!$report.SetupVerified -or $report.Failure -ne 'Outer stdout/stderr EOF exceeded three seconds while the descendant remained alive.' -or
            $report.StdoutEofWithinThreeSeconds -or $report.StderrEofWithinThreeSeconds -or
            !$report.DescendantAliveAfterEofWait -or !$report.DescendantKillRequested -or !$report.DescendantTerminationConfirmed -or
            !$report.StdoutEofAfterDescendantKill -or !$report.StderrEofAfterDescendantKill) {
            throw 'Intentional inherited-pipe control did not reproduce the exact EOF failure on both streams.'
        }
    } elseif ($report.Failure) {
        throw $report.Failure
    }
}
Write-Host 'PASS: outer runner reaches EOF with live descendants; intentional inherited-pipe control rejects missing EOF.'
