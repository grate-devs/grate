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
param([string]$RecordPath, [string]$PidPath, [string]$Mode)
$PID | Set-Content -LiteralPath $PidPath
Remove-Item -LiteralPath $RecordPath -Force
New-Item -ItemType Directory -Path $RecordPath | Out-Null
Write-Output 'diagnostic-path-replaced'
if ($Mode -eq 'Hang') { [Threading.Thread]::Sleep(60000) }
'@ | Set-Content -LiteralPath $faultWorker
    foreach ($mode in @('Hang', 'Success')) {
        $name = "diagnostic-fault-$mode"
        $failure = $null
        try {
            Invoke-InstallerLifecycleProcess -Executable $pwsh -Arguments @(
                '-NoProfile', '-File', $faultWorker, "$root/$name.command.json", "$root/$name.pid", $mode
            ) -Name $name -OutputDirectory $root -TimeoutMilliseconds 5000
        } catch {
            $failure = $_.Exception
        }
        if (!(Test-Path -LiteralPath "$root/$name.pid") -or !(Test-Path -LiteralPath "$root/$name.command.json" -PathType Container)) {
            throw 'Filesystem diagnostic fault was not established by the running worker.'
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
}
finally {
    foreach ($pidPath in @(Get-ChildItem -LiteralPath $root -Filter 'diagnostic-fault-*.pid' -File)) {
        $owned = Get-Process -Id ([int](Get-Content -LiteralPath $pidPath.FullName)) -ErrorAction SilentlyContinue
        if ($owned -and !$owned.HasExited) {
            $owned.Kill()
            [void]$owned.WaitForExit(1000)
        }
    }
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
    if ($null -ne $descendant) {
        $descendant.Dispose()
    }
    Remove-Item -LiteralPath $root -Recurse -Force
}
