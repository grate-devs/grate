#!/usr/bin/env pwsh
. "$PSScriptRoot/monitor-test-containers.ps1"
$directory = Join-Path ([IO.Path]::GetTempPath()) ('grate-monitor-' + [guid]::NewGuid().ToString('N'))
$null = [IO.Directory]::CreateDirectory($directory)
$oldDirectory = $env:GRATE_MONITOR_TEST_DIRECTORY
$oldFailInspection = $env:GRATE_MONITOR_TEST_FAIL_INSPECTION
$oldCloseEvents = $env:GRATE_MONITOR_TEST_CLOSE_EVENTS
$oldResourceStall = $env:GRATE_MONITOR_TEST_RESOURCE_STALL
$env:GRATE_MONITOR_TEST_DIRECTORY = $directory
$env:GRATE_MONITOR_TEST_FAIL_INSPECTION=''
$env:GRATE_MONITOR_TEST_CLOSE_EVENTS=''
$env:GRATE_MONITOR_TEST_RESOURCE_STALL=''
$id = 'a' * 64
function Assert-Monitor([bool]$Condition, [string]$Because) { if (!$Condition) { throw $Because } }
$pwsh = (Get-Process -Id $PID).Path
try {
    $fake = Join-Path $directory 'fake-monitor-command.ps1'
    [IO.File]::WriteAllText($fake, @'
$ErrorActionPreference='Stop'
$directory=$env:GRATE_MONITOR_TEST_DIRECTORY
$tool=$args[0];$arguments=@($args | Select-Object -Skip 1)
[IO.File]::WriteAllText((Join-Path $directory ([guid]::NewGuid().ToString('N')+'.json')),(@{Tool=$tool;Arguments=$arguments;Pid=$PID}|ConvertTo-Json -Depth 10 -Compress))
if ($tool -ne 'docker') { "$tool fixture output"; exit 0 }
switch ($arguments[0]) {
    'events' {
        [IO.File]::WriteAllText((Join-Path $directory 'events.pid'),[string]$PID)
        if ($env:GRATE_MONITOR_TEST_RESOURCE_STALL) { while ($true) { Start-Sleep -Seconds 10 } }
        ('b'*64)+' 0 postgres:17'
        ('c'*64)+' 1 unrelated:latest'
        ('d'*64)+' 1 postgres:17 unexpected-field'
        ('a'*64)+' 137 postgres:17'
        [Console]::Out.Flush()
        if ($env:GRATE_MONITOR_TEST_CLOSE_EVENTS) { [Console]::Error.WriteLine('fixture stream ended');exit 3 }
        while ($true) { Start-Sleep -Seconds 10 }
    }
    'inspect' {
        if ($arguments[2].Contains('.Config') -or $arguments[2].Contains('.Source')) { throw 'Unsafe inspect template.' }
        if ($env:GRATE_MONITOR_TEST_FAIL_INSPECTION) { [Console]::Error.WriteLine('fixture container removed');exit 9 }
        '{"state":{"exitCode":137,"oomKilled":true}}'
    }
    'logs' { 'fixture database crash log' }
    'ps' {
        if ($env:GRATE_MONITOR_TEST_RESOURCE_STALL) {
            [IO.File]::WriteAllText((Join-Path $directory 'resource-stall.pid'),[string]$PID)
            Start-Sleep -Seconds 60
        }
        'fixture resource output'
    }
    'hang' {
        $info=[Diagnostics.ProcessStartInfo]::new((Get-Process -Id $PID).Path)
        $info.ArgumentList.Add('-NoProfile');$info.ArgumentList.Add('-Command');$info.ArgumentList.Add('Start-Sleep -Seconds 60')
        $child=[Diagnostics.Process]::Start($info)
        [IO.File]::WriteAllText((Join-Path $directory 'child.pid'),[string]$child.Id)
        Start-Sleep -Seconds 60
    }
    default { 'fixture resource output' }
}
'@)
    $commands = @{}
    foreach ($tool in @('docker','free','df')) { $commands[$tool]=@{File=$pwsh;Prefix=@('-NoLogo','-NoProfile','-File',$fake,$tool)} }

    foreach ($image in @('mcr.microsoft.com/mssql/server:2022','mcr.microsoft.com/mssql/server@sha256:abc','postgres:17','postgres@sha256:abc','mariadb:11','mariadb@sha256:abc','gvenzl/oracle-free:23','gvenzl/oracle-xe@sha256:abc')) {
        $event=ConvertFrom-MonitorEvent "$id 001 $image"
        Assert-Monitor ($event.Id -ceq $id -and $event.ExitCode -eq 1 -and $event.Image -ceq $image) "Rejected supported database image $image."
    }
    foreach ($line in @("$id 0 postgres:17","$id 256 postgres:17","$id -1 postgres:17","$id 1000 postgres:17","$id 1 unrelated:latest","$id 1 PostgreSQL:17","$id 1 postgres:17 extra",'bad 1 postgres:17')) {
        Assert-Monitor ($null -eq (ConvertFrom-MonitorEvent $line)) "Accepted invalid database failure event: $line"
    }
    Write-Host 'PASS: database image allowlist, exact event fields and exit-code/id validation.'

    $output = Join-Path $directory 'results'
    Invoke-ContainerMonitor $output -DurationSeconds 3 -SampleIntervalSeconds 0.5 -Commands $commands
    $diagnostics = Join-Path $output 'container-diagnostics'
    $captures = @(Get-ChildItem -LiteralPath $diagnostics -Directory)
    Assert-Monitor ($captures.Count -eq 1) 'Only the failed, allowlisted database event may be captured.'
    $capture = $captures[0].FullName
    Assert-Monitor ([IO.File]::ReadAllText("$capture/event.txt").Contains('exitCode=137 image=postgres:17')) 'Failure event metadata is missing.'
    Assert-Monitor ([IO.File]::ReadAllText("$capture/inspect.json").Contains('"oomKilled":true')) 'Inspection output was not retained.'
    Assert-Monitor ([IO.File]::ReadAllText("$capture/container.log").Contains('fixture database crash log')) 'Database crash log was not retained.'
    $resources = [IO.File]::ReadAllText((Join-Path $diagnostics 'resources.log'))
    Assert-Monitor ($resources.Contains('free fixture output') -and $resources.Contains('df fixture output') -and $resources.Contains('::endgroup::')) 'Immediate resource sample is missing or incomplete.'
    $records = @(Get-ChildItem -LiteralPath $directory -Filter '*.json' | ForEach-Object { Get-Content -LiteralPath $_.FullName -Raw | ConvertFrom-Json -AsHashtable })
    Assert-Monitor (@($records | Where-Object Tool -CEQ 'free').Count -ge 2) 'Resource sampling must repeat while the event stream remains open.'
    foreach ($record in $records) { Assert-Monitor ($null -eq (Get-Process -Id $record.Pid -ErrorAction SilentlyContinue)) 'Monitor cleanup left a native subprocess running.' }
    $inspect = @($records | Where-Object { $_.Tool -ceq 'docker' -and $_.Arguments[0] -ceq 'inspect' })
    Assert-Monitor ($inspect.Count -eq 1) 'Unexpected inspection commands.'
    $template = $inspect[0].Arguments[2]
    Assert-Monitor ($template.Contains('$i') -and $template.Contains('$m') -and $template.Contains('.State.OOMKilled') -and $template.Contains('.HostConfig.Memory') -and !$template.Contains('.Config') -and !$template.Contains('.Source')) 'Inspect fields must remain literal and exclude environment variables/host paths.'
    $eventPid=[int][IO.File]::ReadAllText((Join-Path $directory 'events.pid'))
    Assert-Monitor ($null -eq (Get-Process -Id $eventPid -ErrorAction SilentlyContinue)) 'Event subprocess was orphaned.'
    Write-Host 'PASS: concurrent event/resources capture, explicit safe inspection, logs and event-process cleanup.'

    $env:GRATE_MONITOR_TEST_FAIL_INSPECTION='1'
    Save-MonitorFailure @{Id=$id;ExitCode=1;Image='postgres:17'} $diagnostics $commands
    $failedCapture = Get-ChildItem -LiteralPath $diagnostics -Directory | Sort-Object Name | Select-Object -Last 1
    Assert-Monitor ([IO.File]::ReadAllText((Join-Path $failedCapture.FullName 'inspect-error.txt')).Contains('failed or timed out')) 'Failed inspection needs diagnostic context.'
    Assert-Monitor ([IO.File]::ReadAllText((Join-Path $failedCapture.FullName 'container.log')).Contains('fixture database crash log')) 'Inspection failure must not prevent logs.'
    Write-Host 'PASS: missing/removed container inspection remains diagnostic and does not suppress logs.'

    $result = Invoke-MonitorCommand $commands docker @('hang') 1.5
    Assert-Monitor ($result.TimedOut -and $result.ExitCode -ne 0) 'Native timeout must stop a hanging command.'
    Assert-Monitor ($null -eq (Get-Process -Id $result.ProcessId -ErrorAction SilentlyContinue)) 'Timed-out native process survived.'
    $childPid=[int][IO.File]::ReadAllText((Join-Path $directory 'child.pid'))
    Assert-Monitor ($null -eq (Get-Process -Id $childPid -ErrorAction SilentlyContinue)) 'Timed-out native descendant survived.'
    Write-Host 'PASS: bounded native command and descendant-process cleanup.'

    $env:GRATE_MONITOR_TEST_RESOURCE_STALL='1'
    $streamingDirectory = Join-Path $directory 'interrupted-sample'
    $monitorShell = [PowerShell]::Create()
    try {
        $null = $monitorShell.AddScript('param($helper,$directory,$commands); . $helper; Invoke-ContainerMonitor $directory -Commands $commands -CommandTimeoutSeconds 3').AddArgument($script:MonitorHelperPath).AddArgument($streamingDirectory).AddArgument($commands)
        $monitorResult = $monitorShell.BeginInvoke()
        $deadline = [DateTimeOffset]::UtcNow.AddSeconds(15)
        $stallPidPath = Join-Path $directory 'resource-stall.pid'
        while (!(Test-Path -LiteralPath $stallPidPath) -and !$monitorResult.IsCompleted -and [DateTimeOffset]::UtcNow -lt $deadline) { Start-Sleep -Milliseconds 20 }
        Assert-Monitor (Test-Path -LiteralPath $stallPidPath) 'Fixture did not reach the deliberately stalled Docker resource command.'
        $resourceLog = Join-Path $streamingDirectory 'container-diagnostics/resources.log'
        Assert-Monitor (Test-Path -LiteralPath $resourceLog) 'Host metrics must be saved before the Docker resource command completes.'
        $partialSample = [IO.File]::ReadAllText($resourceLog)
        Assert-Monitor ($partialSample.Contains('free fixture output') -and $partialSample.Contains('df fixture output')) 'Already captured host metrics must survive an interrupted resource sample.'
    } finally {
        $monitorShell.Stop()
        $monitorShell.Dispose()
        $env:GRATE_MONITOR_TEST_RESOURCE_STALL=''
    }
    foreach ($pidPath in @('events.pid','resource-stall.pid')) {
        $stoppedPid=[int][IO.File]::ReadAllText((Join-Path $directory $pidPath))
        Assert-Monitor ($null -eq (Get-Process -Id $stoppedPid -ErrorAction SilentlyContinue)) 'Interrupted monitor left an event or resource subprocess running.'
    }
    Assert-Monitor ([IO.File]::ReadAllText($resourceLog).Contains('df fixture output')) 'Monitor teardown discarded the partial host-resource log.'
    Write-Host 'PASS: interrupted Docker resource sample retains immediate host metrics and cleans native workers.'

    $env:GRATE_MONITOR_TEST_CLOSE_EVENTS='1'
    Invoke-ContainerMonitor (Join-Path $directory 'closed-stream') -DurationSeconds 3 -Commands $commands
    Assert-Monitor ([IO.File]::ReadAllText((Join-Path $directory 'closed-stream/container-diagnostics/events-error.txt')).Contains('fixture stream ended')) 'Event failure stderr must be retained.'
    Assert-Monitor (Test-Path -LiteralPath (Join-Path $directory 'closed-stream/container-diagnostics/resources.log')) 'Resource sampling must continue after event-stream failure.'
    Write-Host 'PASS: event stream failure retains errors while resource sampling continues.'
} finally {
    $env:GRATE_MONITOR_TEST_DIRECTORY=$oldDirectory
    $env:GRATE_MONITOR_TEST_FAIL_INSPECTION=$oldFailInspection
    $env:GRATE_MONITOR_TEST_CLOSE_EVENTS=$oldCloseEvents
    $env:GRATE_MONITOR_TEST_RESOURCE_STALL=$oldResourceStall
    Remove-Item -LiteralPath $directory -Recurse -Force
}
