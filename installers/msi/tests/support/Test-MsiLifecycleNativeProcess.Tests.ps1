#!/usr/bin/env pwsh
param(
    [string]$OutputDirectory = (Join-Path $env:RUNNER_TEMP 'msi-native-process-controls')
)

$ErrorActionPreference = 'Stop'
if (!$IsWindows -or $env:GITHUB_ACTIONS -ne 'true' -or $env:RUNNER_ENVIRONMENT -ne 'github-hosted') {
    throw 'Native MSI worker controls require a disposable GitHub-hosted Windows runner.'
}
if ($null -eq ('Grate.MsiTests.MsiLifecycleNativeProcess' -as [type])) {
    Add-Type -Path (Join-Path $PSScriptRoot 'MsiLifecycle.NativeProcess.cs') -ErrorAction Stop
}
$OutputDirectory = [IO.Path]::GetFullPath($OutputDirectory)
New-Item -ItemType Directory -Path $OutputDirectory | Out-Null
$workingDirectory = Join-Path $OutputDirectory 'working directory with spaces'
New-Item -ItemType Directory -Path $workingDirectory | Out-Null
$pwsh = (Get-Process -Id $PID).Path

function Assert-NativeFailure {
    param(
        [scriptblock]$Action,
        [int]$ErrorCode
    )
    $failure = $null
    try {
        & $Action
    } catch {
        $failure = $_.Exception
    }
    while ($null -ne $failure -and $null -ne $failure.InnerException) {
        $failure = $failure.InnerException
    }
    if ($failure -isnot [ComponentModel.Win32Exception] -or $failure.NativeErrorCode -ne $ErrorCode) {
        throw "Native setup failure did not preserve Win32 error $ErrorCode."
    }
}

function Assert-FileHandleClosed {
    param(
        [string]$Path
    )
    $stream = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
    $stream.Dispose()
}

foreach ($attempt in 1..5) {
    $stdout = Join-Path $OutputDirectory "missing-$attempt.stdout.log"
    $stderr = Join-Path $OutputDirectory "missing-$attempt.stderr.log"
    Assert-NativeFailure {
        [Grate.MsiTests.MsiLifecycleNativeProcess]::Start(
            (Join-Path $OutputDirectory 'nonexistent.exe'), '', $stdout, $stderr, $workingDirectory)
    } 2
    Assert-FileHandleClosed $stdout
    Assert-FileHandleClosed $stderr
}
$partialOutput = Join-Path $OutputDirectory 'partial.stdout.log'
Assert-NativeFailure {
    [Grate.MsiTests.MsiLifecycleNativeProcess]::Start(
        $pwsh, '', $partialOutput, (Join-Path $OutputDirectory 'absent/stderr.log'), $workingDirectory)
} 3
Assert-FileHandleClosed $partialOutput

$worker = Join-Path $OutputDirectory 'native worker with spaces.ps1'
@'
param([string]$Observation, [string]$Mode)
[Console]::Out.WriteLine('Native helper stdout marker')
[Console]::Error.WriteLine('Native helper stderr marker')
[Environment]::CurrentDirectory | Set-Content -LiteralPath $Observation
if ($Mode -eq 'Hang') { [Threading.Thread]::Sleep(60000) }
exit 37
'@ | Set-Content -LiteralPath $worker
foreach ($mode in @('RapidExit', 'Hang')) {
    $stdout = Join-Path $OutputDirectory "$mode.stdout.log"
    $stderr = Join-Path $OutputDirectory "$mode.stderr.log"
    $observation = Join-Path $OutputDirectory "$mode.cwd.txt"
    $arguments = '-NoLogo -NoProfile -NonInteractive -File "{0}" -Observation "{1}" -Mode {2}' -f $worker, $observation, $mode
    $process = $null
    try {
        $process = [Grate.MsiTests.MsiLifecycleNativeProcess]::Start($pwsh, $arguments, $stdout, $stderr, $workingDirectory)
        if ($process.Id -le 0) {
            throw 'Native worker did not retain its creation PID.'
        }
        if ($mode -eq 'Hang') {
            $watch = [Diagnostics.Stopwatch]::StartNew()
            while (!(Test-Path -LiteralPath $observation)) {
                if ($watch.Elapsed.TotalSeconds -gt 5) {
                    throw 'Controlled native worker did not become ready.'
                }
                [Threading.Thread]::Sleep(20)
            }
            if ($process.WaitForExit(0)) {
                throw 'Controlled native worker exited before termination was tested.'
            }
            $process.Kill()
        }
        if (!$process.WaitForExit(5000)) {
            throw 'Native worker did not terminate within five seconds.'
        }
        $expectedExit = if ($mode -eq 'RapidExit') { 37 } else { 1 }
        if ($process.ExitCode -ne $expectedExit) {
            throw 'Native worker exit code was not retained through its owned handle.'
        }
        $process.Kill() # Natural/already-terminated exit race must remain safe.
    } finally {
        if ($null -ne $process) {
            try {
                if (!$process.WaitForExit(0)) {
                    $process.Kill()
                    if (!$process.WaitForExit(5000)) {
                        throw 'Native control cleanup did not terminate its owned worker.'
                    }
                }
            } finally {
                $process.Dispose()
            }
        }
    }
    if ((Get-Content -LiteralPath $observation -Raw).Trim() -ne $workingDirectory) {
        throw 'Native launch did not preserve the explicit PowerShell filesystem working directory.'
    }
    foreach ($stream in @('stdout', 'stderr')) {
        $path = Join-Path $OutputDirectory "$mode.$stream.log"
        if ((Get-Content -LiteralPath $path -Raw) -notlike "*Native helper $stream marker*") {
            throw "Native worker $stream was not written to its file handle."
        }
        Assert-FileHandleClosed $path
    }
}
@{
    Succeeded = $true
    Architecture = [Runtime.InteropServices.RuntimeInformation]::ProcessArchitecture.ToString()
    Checks = @('CreateProcessFailure2', 'PartialFileSetupFailure3', 'RapidExit37AndWorkingDirectory', 'BoundedKillWait1')
} | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $OutputDirectory 'result.json')
Write-Host 'PASS: native worker creation errors, partial setup cleanup, file handles, cwd, exit code and bounded termination.'
