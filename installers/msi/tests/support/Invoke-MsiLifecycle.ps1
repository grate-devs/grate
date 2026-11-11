#!/usr/bin/env pwsh
# Keep native MSI/COM work in a disposable child, without supervisor-owned pipes.
param(
    [Parameter(Mandatory)][hashtable]$Parameters,
    [ValidateRange(1, 360)][int]$TimeoutSeconds = 300,
    [string]$ScriptPath = (Join-Path $PSScriptRoot '../Test-WinGetMsiLifecycle.ps1')
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
if (!$IsWindows -or $env:GITHUB_ACTIONS -ne 'true' -or $env:RUNNER_ENVIRONMENT -ne 'github-hosted') {
    throw 'MSI lifecycle supervision requires a disposable GitHub-hosted Windows runner.'
}

$watch = [Diagnostics.Stopwatch]::StartNew()
$directory = [IO.Path]::GetFullPath([string]$Parameters.OutputDirectory) + '-supervisor'
if (Test-Path -LiteralPath $directory) {
    throw 'Supervisor evidence directory must be new.'
}
New-Item -ItemType Directory -Path $directory | Out-Null
$settings = Join-Path $directory 'parameters.json'
$Parameters | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $settings
$resolvedScript = (Resolve-Path -LiteralPath $ScriptPath).Path
$worker = Join-Path $directory 'worker.ps1'
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'MsiLifecycle.Worker.ps1') -Destination $worker
foreach ($name in @('stdout.log', 'stderr.log')) {
    New-Item -ItemType File -Path (Join-Path $directory $name) | Out-Null
}

# Start-Process on Windows puts these file handles directly in STARTUPINFO.
# Unlike ProcessStartInfo redirection, it creates no parent-owned pipe readers.
# The quoted values are Windows file paths, which cannot contain a double quote.
$workerArguments = @(
    '-NoLogo', '-NoProfile', '-NonInteractive', '-MTA', '-File', ('"{0}"' -f $worker),
    '-Settings', ('"{0}"' -f $settings), '-Script', ('"{0}"' -f $resolvedScript)
)
$process = $null
$result = [ordered]@{
    Script = $resolvedScript
    TimeoutSeconds = $TimeoutSeconds
    StartedUtc = [DateTime]::UtcNow.ToString('o')
    TimedOut = $false
    ExitCode = $null
}

function Write-SupervisorPhase {
    param(
        [string]$Phase
    )
    $result.Phase = $Phase
    $result.ElapsedSeconds = $watch.Elapsed.TotalSeconds
    $result | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $directory 'process.json')
    @{
        Phase = $Phase
        Utc = [DateTime]::UtcNow.ToString('o')
        ElapsedSeconds = $watch.Elapsed.TotalSeconds
    } | ConvertTo-Json -Compress | Add-Content -LiteralPath (Join-Path $directory 'phases.jsonl')
}

try {
    Write-SupervisorPhase 'BeforeStart'
    $process = Start-Process -FilePath (Join-Path $PSHOME 'pwsh.exe') -ArgumentList $workerArguments `
        -NoNewWindow -PassThru -RedirectStandardOutput (Join-Path $directory 'stdout.log') `
        -RedirectStandardError (Join-Path $directory 'stderr.log')
    $result.ProcessId = $process.Id
    Write-SupervisorPhase 'AfterStart'
    # Preserve the full worker budget; termination has a separate ten-second bound.
    $executionMilliseconds = $TimeoutSeconds * 1000
    Write-SupervisorPhase 'BeforeWait'
    $exited = $process.WaitForExit([int]$executionMilliseconds)
    Write-SupervisorPhase 'AfterWait'
    if (!$exited) {
        $result.TimedOut = $true
        $result.KillRequestedUtc = [DateTime]::UtcNow.ToString('o')
        Write-SupervisorPhase 'BeforeKill'
        # Avoid process-tree enumeration: the owned worker is stopped directly,
        # and a failed step never queries installers again on this disposable VM.
        $process.Kill()
        Write-SupervisorPhase 'AfterKill'
        $remainingMilliseconds = 10000
        Write-SupervisorPhase 'BeforeTerminationWait'
        $exited = $process.WaitForExit([int]$remainingMilliseconds)
        Write-SupervisorPhase 'AfterTerminationWait'
        if (!$exited) {
            throw 'MSI worker could not be terminated within ten seconds.'
        }
    }
    $result.ExitCode = $process.ExitCode
    if ($result.TimedOut) {
        throw "MSI lifecycle worker exceeded $TimeoutSeconds seconds; partial installer and inventory evidence is retained."
    }
    if ($result.ExitCode -ne 0) {
        throw "MSI lifecycle worker failed with exit code $($result.ExitCode); inspect native and supervisor evidence."
    }
} finally {
    Write-SupervisorPhase 'BeforeDispose'
    # No redirected readers exist here, so disposal cannot wait for descendants.
    if ($null -ne $process) {
        $process.Dispose()
    }
    $result.CompletedUtc = [DateTime]::UtcNow.ToString('o')
    Write-SupervisorPhase 'Completed'
}
