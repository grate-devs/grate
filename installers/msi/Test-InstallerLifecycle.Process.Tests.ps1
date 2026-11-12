#!/usr/bin/env pwsh
param(
    [string]$HelperPath = (Join-Path $PSScriptRoot 'InstallerLifecycle.Process.ps1')
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'InstallerLifecycle.Diagnostics.ps1')
. $HelperPath

function Assert-RejectedProcess {
    param(
        [scriptblock]$Action,
        [string]$Message
    )

    try {
        & $Action
    }
    catch {
        if ($_.Exception.Message -like $Message) {
            return
        }
        throw
    }
    throw "Expected process rejection: $Message"
}

$root = [IO.Directory]::CreateTempSubdirectory('grate-msi-process-').FullName
$pwsh = (Get-Process -Id $PID).Path
$descendant = $null
$primaryFailure = $null
try {
    $worker = Join-Path $root 'worker.ps1'
    @'
param([string]$RecordPath)
$record = Get-Content -LiteralPath $RecordPath -Raw | ConvertFrom-Json
if ($record.state -notin @('Starting', 'Running')) { throw 'Command evidence must exist before waiting.' }
'stdout-marker'
[Console]::Error.WriteLine('stderr-marker')
'@ | Set-Content -LiteralPath $worker
    Invoke-InstallerLifecycleProcess -Executable $pwsh -Arguments @('-NoProfile', '-File', $worker, "$root/success.command.json") `
        -Name 'success' -OutputDirectory $root
    $success = Get-Content -LiteralPath "$root/success.command.json" -Raw | ConvertFrom-Json
    $output = Get-Content -LiteralPath "$root/success.output.log" -Raw
    if ($success.state -ne 'Completed' -or $success.exitCode -ne 0 -or !$output.Contains('stdout-marker') -or !$output.Contains('stderr-marker')) {
        throw 'Successful process evidence or output was lost.'
    }

    Assert-RejectedProcess {
        Invoke-InstallerLifecycleProcess -Executable $pwsh -Arguments @('-NoProfile', '-Command', 'exit 17') `
            -Name 'rejected' -OutputDirectory $root
    } '*exit code 17*'
    Invoke-InstallerLifecycleProcess -Executable $pwsh -Arguments @('-NoProfile', '-Command', 'exit 17') `
        -Name 'allowed' -OutputDirectory $root -AllowedExitCodes @(17)

    Assert-RejectedProcess {
        Invoke-InstallerLifecycleProcess -Executable $pwsh -Arguments @('-NoProfile', '-Command', 'Start-Sleep -Seconds 60') `
            -Name 'timeout' -OutputDirectory $root -TimeoutMilliseconds 200
    } '*exceeded its process timeout*'
    $timeout = Get-Content -LiteralPath "$root/timeout.command.json" -Raw | ConvertFrom-Json
    if (!$timeout.timedOut -or $timeout.state -ne 'Failed') {
        throw 'Process timeout evidence was not retained.'
    }

    # The worker corrupts the record path while it is alive. Evidence failures
    # after WaitForExit must not bypass Kill/Dispose or replace the timeout error.
    $faultWorker = Join-Path $root 'diagnostic-fault.ps1'
    @'
param([string]$RecordPath, [string]$PidPath, [string]$Mode, [string]$PhasePath)
$ErrorActionPreference = 'Stop'
$PID | Set-Content -LiteralPath $PidPath
$watch = [Diagnostics.Stopwatch]::StartNew()
$beforeWait = $null
while ($null -eq $beforeWait) {
    try {
        $beforeWait = Get-Content -LiteralPath $PhasePath -ErrorAction Stop |
            ForEach-Object { $_ | ConvertFrom-Json -ErrorAction Stop } |
            Where-Object Phase -EQ 'BeforeWait' | Select-Object -First 1
    } catch {
        # The phase file can still be absent or contain an in-progress append.
        $beforeWait = $null
    }
    if ($watch.Elapsed.TotalSeconds -gt 3) {
        throw 'The diagnostic fault worker did not observe BeforeWait within its synchronization bound.'
    }
    if ($null -eq $beforeWait) {
        [Threading.Thread]::Sleep(10)
    }
}
# BeforeWait is appended after the command record has been closed. No parent
# record writes can overlap sabotage while it is blocked in WaitForExit.
$beforeWait | ConvertTo-Json | Set-Content -LiteralPath ($PidPath + '.synchronized.json')
Remove-Item -LiteralPath $RecordPath -Force
New-Item -ItemType Directory -Path $RecordPath | Out-Null
@{
    ProcessId = $PID
    ReadyUtc = [DateTime]::UtcNow.ToString('o')
    ObservedBeforeWaitUtc = $beforeWait.Utc
} | ConvertTo-Json | Set-Content -LiteralPath ($PidPath + '.fault-ready.json')
Write-Output 'diagnostic-path-replaced'
if ($Mode -eq 'Hang') { [Threading.Thread]::Sleep(60000) }
'@ | Set-Content -LiteralPath $faultWorker
    foreach ($mode in @('Hang', 'Success')) {
        $name = "diagnostic-fault-$mode"
        $failure = $null
        try {
            Invoke-InstallerLifecycleProcess -Executable $pwsh -Arguments @(
                '-NoProfile', '-File', $faultWorker, "$root/$name.command.json", "$root/$name.pid", $mode,
                "$root/$name.process-phases.jsonl"
            ) -Name $name -OutputDirectory $root -TimeoutMilliseconds 5000
        } catch {
            $failure = $_.Exception
        }
        if (!(Test-Path -LiteralPath "$root/$name.pid") -or !(Test-Path -LiteralPath "$root/$name.command.json" -PathType Container)) {
            throw 'Filesystem diagnostic fault was not established by the running worker.'
        }
        $synchronization = Get-Content -LiteralPath "$root/$name.pid.synchronized.json" -Raw | ConvertFrom-Json
        if ($synchronization.Phase -ne 'BeforeWait') {
            throw 'Filesystem sabotage did not synchronize with the parent wait.'
        }
        $ready = Get-Content -LiteralPath "$root/$name.pid.fault-ready.json" -Raw | ConvertFrom-Json
        $beforeWaitUtc = [DateTime]::Parse($ready.ObservedBeforeWaitUtc).ToUniversalTime()
        $readyUtc = [DateTime]::Parse($ready.ReadyUtc).ToUniversalTime()
        if ($readyUtc -lt $beforeWaitUtc -or $readyUtc -ge $beforeWaitUtc.AddSeconds(5)) {
            throw 'Filesystem diagnostic fault was not established within the parent wait budget.'
        }
        $owned = Get-Process -Id ([int](Get-Content -LiteralPath "$root/$name.pid")) -ErrorAction SilentlyContinue
        if ($owned -and !$owned.HasExited) {
            throw 'Owned process survived a diagnostic write failure; cleanup was bypassed.'
        }
        $expectedMessage = if ($mode -eq 'Hang') { '*exceeded its process timeout*' } else { '*diagnostic evidence could not be retained*' }
        if (!$failure -or $failure.Message -notlike $expectedMessage) {
            throw "Diagnostic fault did not preserve the expected $mode failure."
        }
        $diagnostics = Get-Content -LiteralPath "$root/$name.diagnostics.json" -Raw | ConvertFrom-Json
        if (!@($diagnostics.Failures).Count -or $diagnostics.Snapshot.phase -ne 'AfterDispose' -or !$diagnostics.Snapshot.completedUtc) {
            throw 'Diagnostic failure or completed disposal was not retained in the fallback report.'
        }
        Assert-InstallerLifecyclePhaseOrder -Path "$root/$name.process-phases.jsonl" -RequiredPhases @(
            'BeforeStart', 'BeforeWait', 'AfterWait', 'BeforeDispose', 'AfterDispose'
        )
    }

    # A parent can exit successfully while its child retains the output pipes.
    # This is the case an ordinary WaitForExit timeout cannot bound.
    $parent = Join-Path $root 'inherited-pipe.ps1'
    @'
param([string]$Executable, [string]$PidPath)
$start = [Diagnostics.ProcessStartInfo]::new($Executable)
$start.UseShellExecute = $false
foreach ($argument in @('-NoProfile', '-Command', 'Start-Sleep -Seconds 60')) {
    $start.ArgumentList.Add($argument)
}
$child = [Diagnostics.Process]::Start($start)
$child.Id | Set-Content -LiteralPath $PidPath
'parent-exited'
'@ | Set-Content -LiteralPath $parent
    $watch = [Diagnostics.Stopwatch]::StartNew()
    Assert-RejectedProcess {
        Invoke-InstallerLifecycleProcess -Executable $pwsh `
            -Arguments @('-NoProfile', '-File', $parent, $pwsh, "$root/descendant.pid") `
            -Name 'inherited-pipe' -OutputDirectory $root -TimeoutMilliseconds 10000 -DrainTimeoutMilliseconds 200
    } '*output drain failed or exceeded its timeout*'
    $drain = Get-Content -LiteralPath "$root/inherited-pipe.command.json" -Raw | ConvertFrom-Json
    if ($drain.exitCode -ne 0 -or $drain.timedOut -or !$drain.streamDrainFailure -or $watch.Elapsed.TotalSeconds -gt 15) {
        throw 'Inherited pipe handles were not rejected within the drain bound.'
    }
    foreach ($name in @('success', 'rejected', 'allowed', 'timeout', 'inherited-pipe')) {
        $phases = @('BeforeStart', 'BeforeWait', 'AfterWait')
        if ($name -eq 'timeout') {
            $phases += @('BeforeKill', 'AfterKill', 'BeforeTerminationWait', 'AfterTerminationWait')
        }
        $phases += @('BeforeDispose', 'AfterDispose')
        Assert-InstallerLifecyclePhaseOrder -Path "$root/$name.process-phases.jsonl" -RequiredPhases $phases
        $diagnostics = Get-Content -LiteralPath "$root/$name.diagnostics.json" -Raw | ConvertFrom-Json
        if (@($diagnostics.Failures).Count -or !$diagnostics.Snapshot.completedUtc) {
            throw 'Ordinary process diagnostics reported missing evidence or incomplete cleanup.'
        }
    }
    $invalidHistory = Join-Path $root 'invalid-phases.jsonl'
    foreach ($phases in @(@('BeforeDispose', 'BeforeWait', 'AfterDispose'), @('BeforeWait', 'BeforeDispose'))) {
        $phases | ForEach-Object { @{ Phase = $_ } | ConvertTo-Json -Compress } | Set-Content -LiteralPath $invalidHistory
        Assert-RejectedProcess {
            Assert-InstallerLifecyclePhaseOrder -Path $invalidHistory -RequiredPhases @('BeforeWait', 'BeforeDispose', 'AfterDispose')
        } '*do not establish ordered execution and completed cleanup*'
    }
    Write-Host 'PASS: early command evidence, stdout/stderr, exit policy, process timeout and inherited-pipe drain timeout.'
} catch {
    $primaryFailure = $_.Exception
    throw
} finally {
    $cleanupFailures = [Collections.Generic.List[Exception]]::new()
    foreach ($pidPath in @(Get-ChildItem -LiteralPath $root -Filter 'diagnostic-fault-*.pid' -File)) {
        $owned = $null
        try {
            $owned = Get-Process -Id ([int](Get-Content -LiteralPath $pidPath.FullName)) -ErrorAction SilentlyContinue
            if ($null -ne $owned) {
                if (!$owned.HasExited) {
                    $owned.Kill()
                }
                if (!$owned.WaitForExit(5000)) {
                    throw 'The diagnostic-fault worker did not terminate within five seconds.'
                }
            }
        } catch {
            $cleanupFailures.Add($_.Exception)
        } finally {
            try {
                if ($null -ne $owned) {
                    $owned.Dispose()
                }
            } catch {
                $cleanupFailures.Add($_.Exception)
            }
        }
    }
    try {
        if (Test-Path -LiteralPath "$root/descendant.pid") {
            $descendantId = [int](Get-Content -LiteralPath "$root/descendant.pid" -Raw)
            $descendant = Get-Process -Id $descendantId -ErrorAction SilentlyContinue
            if ($null -ne $descendant -and !$descendant.HasExited) {
                $descendant.Kill()
                if (!$descendant.WaitForExit(5000)) {
                    throw 'The test-owned descendant did not terminate.'
                }
            }
        }
    } catch {
        $cleanupFailures.Add($_.Exception)
    } finally {
        try {
            if ($null -ne $descendant) {
                $descendant.Dispose()
            }
        } catch {
            $cleanupFailures.Add($_.Exception)
        }
        try {
            Remove-Item -LiteralPath $root -Recurse -Force
        } catch {
            $cleanupFailures.Add($_.Exception)
        }
    }
    foreach ($cleanupFailure in $cleanupFailures) {
        [Console]::Error.WriteLine("Process regression cleanup failed: $($cleanupFailure.Message)")
    }
    if (!$primaryFailure -and $cleanupFailures.Count) {
        throw [AggregateException]::new('Process regression cleanup failed.', $cleanupFailures)
    }
}
