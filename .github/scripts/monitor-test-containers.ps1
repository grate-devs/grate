#!/usr/bin/env pwsh
# GNU timeout supervises the whole process group in CI, including native children.
[CmdletBinding()]
param([string]$ResultsDirectory)
$ErrorActionPreference = 'Stop'
$script:MonitorHelperPath = $PSCommandPath

function Start-MonitorProcess([string]$FilePath, [string[]]$Arguments) {
    $info = [Diagnostics.ProcessStartInfo]::new($FilePath)
    $info.UseShellExecute = $false
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    foreach ($argument in $Arguments) { $info.ArgumentList.Add($argument) }
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $info
    try { if (!$process.Start()) { throw 'Process could not start.' }; return $process }
    catch { $process.Dispose(); throw }
}

function Invoke-MonitorCommand($Commands, [string]$Tool, [string[]]$Arguments, [double]$TimeoutSeconds = 10) {
    $process = $null
    try {
        $command = $Commands[$Tool]
        $process = Start-MonitorProcess $command.File (@($command.Prefix) + $Arguments)
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        $timedOut = !$process.WaitForExit([int]($TimeoutSeconds * 1000))
        if ($timedOut) { $process.Kill($true); $process.WaitForExit() }
        return @{ExitCode=$process.ExitCode;Stdout=$stdout.GetAwaiter().GetResult();Stderr=$stderr.GetAwaiter().GetResult();TimedOut=$timedOut;ProcessId=$process.Id}
    } catch { return @{ExitCode=127;Stdout='';Stderr="$Tool could not complete: $($_.Exception.Message)`n";TimedOut=$false} }
    finally {
        if ($process) {
            if (!$process.HasExited) { $process.Kill($true); $process.WaitForExit() }
            $process.Dispose()
        }
    }
}

function ConvertFrom-MonitorEvent([string]$Line) {
    if ($Line.Trim() -cnotmatch '\A([a-f0-9]{64})\s+([0-9]{1,3})\s+(\S+)\z') { return $null }
    $id = $Matches[1]; $code = [int]$Matches[2]; $image = $Matches[3]
    if ($code -lt 1 -or $code -gt 255) { return $null }
    if ($image -cnotmatch '\A(?:mcr\.microsoft\.com/mssql/server|postgres|mariadb|gvenzl/oracle-[^\s]*)[:@].*\z') { return $null }
    return @{Id=$id;ExitCode=$code;Image=$image}
}

function Save-MonitorFailure($Event, [string]$Directory, $Commands, [double]$TimeoutSeconds = 10) {
    $capture = Join-Path $Directory ([DateTimeOffset]::UtcNow.ToString('yyyyMMddTHHmmss.fffffffZ') + '-' + $Event.Id)
    $null = [IO.Directory]::CreateDirectory($capture)
    $message = "Observed at: $([DateTimeOffset]::UtcNow.ToString('o'))`nContainer die event: id=$($Event.Id) exitCode=$($Event.ExitCode) image=$($Event.Image)`n"
    [IO.File]::WriteAllText((Join-Path $capture 'event.txt'), $message)
    Write-Host $message
    # Explicit fields only: never dump Config.Env, credentials or host bind paths.
    # Single quotes keep Docker's $i/$m template variables literal.
    $template = '{"id":{{json .Id}},"state":{"status":{{json .State.Status}},"exitCode":{{.State.ExitCode}},"oomKilled":{{.State.OOMKilled}},"error":{{json .State.Error}},"startedAt":{{json .State.StartedAt}},"finishedAt":{{json .State.FinishedAt}}},"limits":{"memory":{{.HostConfig.Memory}},"memorySwap":{{.HostConfig.MemorySwap}},"nanoCpus":{{.HostConfig.NanoCpus}},"cpuQuota":{{.HostConfig.CpuQuota}},"cpuPeriod":{{.HostConfig.CpuPeriod}},"pidsLimit":{{json .HostConfig.PidsLimit}},"ulimits":{{json .HostConfig.Ulimits}},"shmSize":{{.HostConfig.ShmSize}}},"mounts":[{{range $i,$m := .Mounts}}{{if $i}},{{end}}{"type":{{json $m.Type}},"name":{{json (index $m "Name")}},"destination":{{json $m.Destination}}}{{end}}]}'
    $inspection = Invoke-MonitorCommand $Commands docker @('inspect','--format',$template,$Event.Id) $TimeoutSeconds
    if ($inspection.ExitCode -ne 0 -or $inspection.TimedOut) { $inspection.Stderr += "Container inspection failed or timed out; it may already have been removed.`n" }
    [IO.File]::WriteAllText((Join-Path $capture 'inspect.json'), $inspection.Stdout)
    [IO.File]::WriteAllText((Join-Path $capture 'inspect-error.txt'), $inspection.Stderr)
    Write-Host ($inspection.Stdout + $inspection.Stderr)
    $logs = Invoke-MonitorCommand $Commands docker @('logs','--timestamps','--tail','200',$Event.Id) $TimeoutSeconds
    $log = $logs.Stdout + $logs.Stderr
    if ($logs.ExitCode -ne 0 -or $logs.TimedOut) { $log += "`nContainer log capture failed or timed out; it may already have been removed.`n" }
    [IO.File]::WriteAllText((Join-Path $capture 'container.log'), $log)
    Write-Host $log
}

function Write-MonitorResources([string]$Directory, $Commands, [double]$TimeoutSeconds = 10) {
    function Write-ResourceSample([string]$Text) {
        # Retain each completed observation before a later Docker command can
        # stall or the test runner stops this worker. Console output must also
        # stream directly instead of waiting for the runspace's EndInvoke.
        [IO.File]::AppendAllText((Join-Path $Directory 'resources.log'), $Text + "`n")
        [Console]::Out.WriteLine($Text)
        [Console]::Out.Flush()
    }
    Write-ResourceSample '::group::Test host and container resources'
    Write-ResourceSample ([DateTimeOffset]::UtcNow.ToString('o'))
    $free = Invoke-MonitorCommand $Commands free @('-h') $TimeoutSeconds
    Write-ResourceSample ($free.Stdout + $free.Stderr)
    if ([IO.File]::Exists('/proc/self/limits')) {
        Write-ResourceSample 'Host process/open-file limits:'
        foreach ($line in [IO.File]::ReadAllLines('/proc/self/limits') | Where-Object { $_ -match '^Max (processes|open files)\s' }) { Write-ResourceSample $line }
    }
    foreach ($command in @(
        @{Tool='df';Arguments=@('-h','/','/dev/shm')},
        @{Tool='docker';Arguments=@('ps','-a','--format','table {{.ID}}\t{{.Image}}\t{{.Status}}\t{{.Names}}')},
        @{Tool='docker';Arguments=@('stats','--no-stream','--format','table {{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}\t{{.BlockIO}}\t{{.PIDs}}')},
        @{Tool='docker';Arguments=@('image','ls','--digests','--format','{{.Repository}}@{{.Digest}} {{.ID}}')}
    )) {
        $result = Invoke-MonitorCommand $Commands $command.Tool $command.Arguments $TimeoutSeconds
        Write-ResourceSample ($result.Stdout + $result.Stderr)
        if ($result.TimedOut) { Write-ResourceSample "$($command.Tool) resource sample timed out." }
    }
    Write-ResourceSample '::endgroup::'
}

function Invoke-ContainerMonitor([string]$Directory, [double]$DurationSeconds = 0, [double]$SampleIntervalSeconds = 60, [double]$CommandTimeoutSeconds = 10, $Commands = $null) {
    if (!$Directory) { throw 'ResultsDirectory is required.' }
    if (!$Commands) {
        $Commands = @{}
        foreach ($tool in @('docker','free','df')) { $Commands[$tool] = @{File=$tool;Prefix=@()} }
    }
    $diagnostics = Join-Path ([IO.Path]::GetFullPath($Directory)) 'container-diagnostics'
    $null = [IO.Directory]::CreateDirectory($diagnostics)
    $started = [DateTimeOffset]::UtcNow
    $eventProcess = $null; $sampleShell = $null; $sampleResult = $null
    try {
        $docker = $Commands.docker
        $eventArguments = @('events','--since',$started.ToString('o'),'--filter','type=container','--filter','event=die','--format','{{.Actor.ID}} {{index .Actor.Attributes "exitCode"}} {{index .Actor.Attributes "image"}}')
        try {
            $eventProcess = Start-MonitorProcess $docker.File (@($docker.Prefix) + $eventArguments)
            $eventErrors = $eventProcess.StandardError.ReadToEndAsync()
            $eventLine = $eventProcess.StandardOutput.ReadLineAsync()
        } catch { Write-Warning "Container event stream could not start: $($_.Exception.Message)" }
        $nextSample = $started
        while ($DurationSeconds -le 0 -or ([DateTimeOffset]::UtcNow - $started).TotalSeconds -lt $DurationSeconds) {
            if ($eventLine -and $eventLine.IsCompleted) {
                $line = $eventLine.GetAwaiter().GetResult()
                if ($null -eq $line) {
                    $eventLine = $null
                    Write-Warning 'Docker event stream ended; host resource sampling continues.'
                } else {
                    $event = ConvertFrom-MonitorEvent $line
                    if ($event) { Save-MonitorFailure $event $diagnostics $Commands $CommandTimeoutSeconds }
                    $eventLine = $eventProcess.StandardOutput.ReadLineAsync()
                }
            }
            if ($sampleResult -and $sampleResult.IsCompleted) {
                try { $sampleShell.EndInvoke($sampleResult) | ForEach-Object { Write-Host $_ } }
                finally { $sampleShell.Dispose(); $sampleShell=$null; $sampleResult=$null }
            }
            if (!$sampleResult -and [DateTimeOffset]::UtcNow -ge $nextSample) {
                $sampleShell = [PowerShell]::Create()
                $null = $sampleShell.AddScript('param($helper,$directory,$commands,$timeout); . $helper; Write-MonitorResources $directory $commands $timeout').AddArgument($script:MonitorHelperPath).AddArgument($diagnostics).AddArgument($Commands).AddArgument($CommandTimeoutSeconds)
                $sampleResult = $sampleShell.BeginInvoke()
                $nextSample = [DateTimeOffset]::UtcNow.AddSeconds($SampleIntervalSeconds)
            }
            Start-Sleep -Milliseconds 50
        }
    } finally {
        if ($sampleShell) { try { $sampleShell.Stop() } finally { $sampleShell.Dispose() } }
        if ($eventProcess) {
            if (!$eventProcess.HasExited) { $eventProcess.Kill($true) }
            $eventProcess.WaitForExit()
            $errors = $eventErrors.GetAwaiter().GetResult()
            if ($errors) { [IO.File]::AppendAllText((Join-Path $diagnostics 'events-error.txt'), $errors); Write-Warning $errors }
            $eventProcess.Dispose()
        }
    }
}

if ($MyInvocation.InvocationName -ne '.') { Invoke-ContainerMonitor $ResultsDirectory }
