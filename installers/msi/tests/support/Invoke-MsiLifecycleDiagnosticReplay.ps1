#!/usr/bin/env pwsh
param(
    [Parameter(Mandatory)][hashtable]$Parameters,
    [string]$ScriptPath = (Join-Path $PSScriptRoot '../../Test-InstallerLifecycle.ps1'),
    [ValidateRange(1, 450)][int]$DeadlineSeconds = 450
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
if (!$IsWindows -or $env:GITHUB_ACTIONS -ne 'true' -or $env:RUNNER_ENVIRONMENT -ne 'github-hosted') {
    throw 'MSI diagnostic replay requires a disposable GitHub-hosted Windows runner.'
}
. (Join-Path $PSScriptRoot '../../InstallerLifecycle.Diagnostics.ps1')
$watch = [Diagnostics.Stopwatch]::StartNew()
$lifecycleDirectory = [IO.Path]::GetFullPath([string]$Parameters.OutputDirectory)
$directory = $lifecycleDirectory + '-replay'
if (Test-Path -LiteralPath $directory) {
    throw 'Diagnostic replay evidence directory must be new.'
}
New-Item -ItemType Directory -Path $directory | Out-Null
$diagnosticFailures = [Collections.Generic.List[Exception]]::new()
$settings = Join-Path $directory 'settings.json'
@{
    Parameters = $Parameters
    TestScript = (Resolve-Path -LiteralPath $ScriptPath).Path
    Supervisor = (Join-Path $PSScriptRoot 'Invoke-MsiLifecycle.ps1')
    NativeSource = (Join-Path $PSScriptRoot 'MsiLifecycle.NativeProcess.cs')
    Diagnostics = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '../../InstallerLifecycle.Diagnostics.ps1')).Path
    EvidenceDirectory = $directory
} | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $settings
$wrapper = Join-Path $directory 'child-wrapper.ps1'
@'
param([string]$Settings)
$ErrorActionPreference = 'Stop'
$replayConfiguration = Get-Content -LiteralPath $Settings -Raw | ConvertFrom-Json -AsHashtable
. $replayConfiguration.Diagnostics
$failures = [Collections.Generic.List[Exception]]::new()
function Write-ChildStage {
    param([string]$Phase)
    $stage = @{
        Phase = $Phase
        Utc = [DateTime]::UtcNow.ToString('o')
    }
    Write-InstallerLifecycleDiagnostic -Path (Join-Path $replayConfiguration.EvidenceDirectory 'child-stage.json') -Value $stage -Failures $failures
    Write-InstallerLifecycleDiagnostic -Path (Join-Path $replayConfiguration.EvidenceDirectory 'child-stages.jsonl') -Value $stage -Failures $failures -Append
}
try {
    Write-ChildStage 'BeforeNativeAddType'
    if ($null -eq ('Grate.MsiTests.MsiLifecycleNativeProcess' -as [type])) {
        Add-Type -Path $replayConfiguration.NativeSource -ErrorAction Stop
    }
    Write-ChildStage 'AfterNativeAddType'
    Write-ChildStage 'BeforeSupervisor'
    & $replayConfiguration.Supervisor -ScriptPath $replayConfiguration.TestScript -Parameters $replayConfiguration.Parameters -TimeoutSeconds 360
    Write-ChildStage 'AfterSupervisor'
    Assert-InstallerLifecycleDiagnostics -Failures $failures
} catch {
    Write-ChildStage 'ChildFailed'
    [Console]::Error.WriteLine($_.Exception.ToString())
    exit 1
}
'@ | Set-Content -LiteralPath $wrapper

$state = [ordered]@{
    StartedUtc = [DateTime]::UtcNow.ToString('o')
    DeadlineSeconds = $DeadlineSeconds
    Phase = 'Prepared'
    ChildProcessId = $null
    ChildExited = $false
    ChildExitCode = $null
    TimedOut = $false
    StdoutComplete = $false
    StderrComplete = $false
    LastChildStage = $null
    Failure = $null
    CleanupFailures = @()
}
$observedFiles = @{}

function Write-ReplayEvent {
    param(
        [string]$Event,
        $Observation = $null
    )
    $record = @{
        Utc = [DateTime]::UtcNow.ToString('o')
        ElapsedSeconds = $watch.Elapsed.TotalSeconds
        Event = $Event
        Observation = $Observation
    }
    Write-InstallerLifecycleDiagnostic -Path (Join-Path $directory 'timeline.jsonl') -Value $record -Failures $diagnosticFailures -Append
    $state.Phase = $Event
    Write-InstallerLifecycleDiagnostic -Path (Join-Path $directory 'controller.json') -Value $state -Failures $diagnosticFailures
}

function Read-ReplayPhases {
    $paths = @(
        (Join-Path $directory 'child-stage.json'),
        ($lifecycleDirectory + '-supervisor/process.json'),
        (Join-Path $lifecycleDirectory 'worker-phase.json')
    )
    if (Test-Path -LiteralPath $lifecycleDirectory -PathType Container) {
        $paths += @(Get-ChildItem -LiteralPath $lifecycleDirectory -Filter '*.command.json' -File -Recurse | ForEach-Object FullName)
    }
    foreach ($path in $paths) {
        if (!(Test-Path -LiteralPath $path -PathType Leaf)) {
            continue
        }
        try {
            $file = Get-Item -LiteralPath $path
            $stamp = "$($file.LastWriteTimeUtc.Ticks):$($file.Length)"
            if ($observedFiles.ContainsKey($path) -and $observedFiles[$path] -eq $stamp) {
                continue
            }
            $value = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
            $observation = [ordered]@{
                Path = $path
                LastWriteUtc = $file.LastWriteTimeUtc.ToString('o')
            }
            # Observe only phase/status fields, never arguments or inventory.
            foreach ($name in @('Phase', 'State', 'ProcessId', 'StartedUtc', 'CompletedUtc', 'ExitCode', 'TimedOut')) {
                $property = $value.PSObject.Properties[$name]
                if ($null -ne $property) {
                    $observation[$name] = $property.Value
                }
            }
            if ($path -eq (Join-Path $directory 'child-stage.json')) {
                $state.LastChildStage = $value.Phase
            }
            Write-ReplayEvent 'PhaseChanged' $observation
            Write-Host "MSI replay phase: $([IO.Path]::GetFileName($path)); $($observation | ConvertTo-Json -Compress)"
            $observedFiles[$path] = $stamp
        } catch {
            # A writer may be between truncation and a completed JSON write.
            Write-ReplayEvent 'PhaseReadPending' @{ Path = $path }
        }
    }
}

$start = [Diagnostics.ProcessStartInfo]::new((Get-Process -Id $PID).Path)
$start.UseShellExecute = $false
$start.CreateNoWindow = $true
$start.RedirectStandardOutput = $true
$start.RedirectStandardError = $true
$start.WorkingDirectory = $ExecutionContext.SessionState.Path.CurrentFileSystemLocation.Path
foreach ($argument in @('-NoLogo', '-NoProfile', '-NonInteractive', '-File', $wrapper, '-Settings', $settings)) {
    $start.ArgumentList.Add($argument)
}
$process = [Diagnostics.Process]::new()
$process.StartInfo = $start
$started = $false
$stdout = $null
$stderr = $null
$primaryFailure = $null
$state.LifecycleCompleted = $false
$state.Succeeded = $false
try {
    Write-ReplayEvent 'BeforeChildStart'
    [void]$process.Start()
    $started = $true
    $state.ChildProcessId = $process.Id
    $stdout = $process.StandardOutput.ReadToEndAsync()
    $stderr = $process.StandardError.ReadToEndAsync()
    Write-ReplayEvent 'AfterChildStart'
    $nextHeartbeat = 0.0
    while (!$state.ChildExited) {
        Read-ReplayPhases
        if ($watch.Elapsed.TotalSeconds -ge $nextHeartbeat) {
            Write-ReplayEvent 'Heartbeat' @{ LastChildStage = $state.LastChildStage }
            Write-Host "MSI replay heartbeat: $([int]$watch.Elapsed.TotalSeconds)s; child=$($state.ChildProcessId); stage=$($state.LastChildStage)"
            $nextHeartbeat = $watch.Elapsed.TotalSeconds + 10
        }
        $remaining = ($DeadlineSeconds - $watch.Elapsed.TotalSeconds) * 1000
        if ($remaining -le 0) {
            $state.TimedOut = $true
            Write-ReplayEvent 'DeadlineExceeded'
            throw "MSI diagnostic replay exceeded its $DeadlineSeconds second deadline; partial evidence is retained."
        }
        $state.ChildExited = $process.WaitForExit([int][Math]::Min(1000, $remaining))
    }
    $state.ChildExitCode = $process.ExitCode
    Write-ReplayEvent 'ChildExited'
    Read-ReplayPhases
    Write-ReplayEvent 'BeforeOutputDrain'
    [void][Threading.Tasks.Task]::WhenAll([Threading.Tasks.Task[]]@($stdout, $stderr)).WaitAsync(
        [TimeSpan]::FromSeconds(3)).GetAwaiter().GetResult()
    Write-ReplayEvent 'AfterOutputDrain'
    if ($state.ChildExitCode -ne 0) {
        throw "MSI diagnostic child failed with exit code $($state.ChildExitCode); inspect retained phase and native logs."
    }
    if ($state.LastChildStage -ne 'AfterSupervisor') {
        throw 'MSI diagnostic child exited without completing the unchanged lifecycle supervisor.'
    }
    $state.LifecycleCompleted = $true
} catch {
    $primaryFailure = $_
    $state.Failure = $_.Exception.Message
    Write-ReplayEvent 'ReplayFailed'
} finally {
    try {
        if ($started -and !$process.HasExited) {
            Write-ReplayEvent 'BeforeOwnedChildKill'
            $process.Kill()
            Write-ReplayEvent 'AfterOwnedChildKill'
            $state.ChildExited = $process.WaitForExit(10000)
            Write-ReplayEvent 'AfterOwnedChildTerminationWait'
            if (!$state.ChildExited) {
                throw 'Owned diagnostic child did not terminate within ten seconds.'
            }
        }
        if ($started -and $process.HasExited) {
            $state.ChildExited = $true
            $state.ChildExitCode = $process.ExitCode
        }
    } catch {
        $state.CleanupFailures += $_.Exception.Message
    }
    # Only the original Process handle is acted on. A worker PID from a phase
    # file has no creation identity and cannot safely authorize reopening/killing.
    $state.WorkerPidCleanup = 'NotAttemptedWithoutCreationIdentity'
    $readersCompleted = ($null -eq $stdout)
    if ($null -ne $stdout) {
        try {
            [void][Threading.Tasks.Task]::WhenAll([Threading.Tasks.Task[]]@($stdout, $stderr)).WaitAsync(
                [TimeSpan]::FromSeconds(3)).GetAwaiter().GetResult()
        } catch {
            $state.CleanupFailures += 'Diagnostic child output did not complete successfully after bounded cleanup.'
        }
        $state.StdoutComplete = $stdout.IsCompletedSuccessfully
        $state.StderrComplete = $stderr.IsCompletedSuccessfully
        $readersCompleted = $stdout.IsCompleted -and $stderr.IsCompleted
        foreach ($stream in @(@{ Name = 'stdout'; Task = $stdout }, @{ Name = 'stderr'; Task = $stderr })) {
            if ($stream.Task.IsCompletedSuccessfully) {
                try {
                    $stream.Task.GetAwaiter().GetResult() | Set-Content -LiteralPath (Join-Path $directory "child.$($stream.Name).log")
                } catch {
                    $diagnosticFailures.Add($_.Exception)
                }
            }
        }
    }
    if ($readersCompleted) {
        try {
            Write-ReplayEvent 'BeforeOwnedChildDispose'
            $process.Dispose()
            Write-ReplayEvent 'AfterOwnedChildDispose'
        } catch {
            $state.CleanupFailures += $_.Exception.Message
        }
    } else {
        $state.CleanupFailures += 'Skipped Process.Dispose while inherited output readers remained pending.'
    }
    $state.CompletedUtc = [DateTime]::UtcNow.ToString('o')
    $state.ElapsedSeconds = $watch.Elapsed.TotalSeconds
    Write-ReplayEvent 'CleanupFinished'
    Write-InstallerLifecycleDiagnostic -Path (Join-Path $directory 'result.json') -Value $state -Failures $diagnosticFailures
    Complete-InstallerLifecycleDiagnostics -Path (Join-Path $directory 'diagnostics.json') -Snapshot $state -Failures $diagnosticFailures
}
if ($null -ne $primaryFailure) {
    throw $primaryFailure
}
if ($state.CleanupFailures.Count) {
    throw 'MSI diagnostic replay cleanup failed; inspect retained result and phase evidence.'
}
Assert-InstallerLifecycleDiagnostics -Failures $diagnosticFailures
$state.Succeeded = $true
Write-ReplayEvent 'ReplaySucceeded'
Write-InstallerLifecycleDiagnostic -Path (Join-Path $directory 'result.json') -Value $state -Failures $diagnosticFailures
Assert-InstallerLifecycleDiagnostics -Failures $diagnosticFailures
Write-Host 'PASS: unchanged MSI lifecycle completed inside the bounded diagnostic replay.'
