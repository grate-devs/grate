#!/usr/bin/env pwsh
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'InstallerLifecycle.Process.ps1')

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
    Write-Host 'PASS: early command evidence, stdout/stderr, exit policy, process timeout and inherited-pipe drain timeout.'
}
finally {
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
