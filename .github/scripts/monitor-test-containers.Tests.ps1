#!/usr/bin/env pwsh
. "$PSScriptRoot/monitor-test-containers.ps1"

$directory = Join-Path ([IO.Path]::GetTempPath()) ('grate-monitor-' + [guid]::NewGuid().ToString('N'))
$null = [IO.Directory]::CreateDirectory($directory)
$oldDirectory = $env:GRATE_MONITOR_TEST_DIRECTORY
$oldFailInspection = $env:GRATE_MONITOR_TEST_FAIL_INSPECTION
$oldCloseEvents = $env:GRATE_MONITOR_TEST_CLOSE_EVENTS
$oldResourceStall = $env:GRATE_MONITOR_TEST_RESOURCE_STALL
$oldInvalidInspection = $env:GRATE_MONITOR_TEST_INVALID_INSPECTION

$env:GRATE_MONITOR_TEST_DIRECTORY = $directory
$env:GRATE_MONITOR_TEST_FAIL_INSPECTION = ''
$env:GRATE_MONITOR_TEST_CLOSE_EVENTS = ''
$env:GRATE_MONITOR_TEST_RESOURCE_STALL = ''
$env:GRATE_MONITOR_TEST_INVALID_INSPECTION = ''
$id = 'a' * 64

function Assert-Monitor {
    param(
        [bool]$Condition,
        [string]$Because
    )

    if (!$Condition) {
        throw $Because
    }
}

function Invoke-MonitorUntilObserved {
    param(
        [string]$ResultsDirectory,
        $Commands,
        [scriptblock]$Observed
    )

    $monitorScript = {
        param($Helper, $OutputDirectory, $Commands)

        . $Helper
        Invoke-ContainerMonitor $OutputDirectory -SampleIntervalSeconds 0.5 -Commands $Commands
    }
    $monitor = [PowerShell]::Create()
    try {
        $null = $monitor.AddScript($monitorScript.ToString())
        $null = $monitor.AddArgument($script:MonitorHelperPath)
        $null = $monitor.AddArgument($ResultsDirectory)
        $null = $monitor.AddArgument($Commands)
        $pending = $monitor.BeginInvoke()
        $deadline = [DateTimeOffset]::UtcNow.AddSeconds(20)

        while (!(& $Observed)) {
            if ($pending.IsCompleted) {
                $null = $monitor.EndInvoke($pending)
                throw 'Monitor ended before the expected fixture observations.'
            }
            if ([DateTimeOffset]::UtcNow -ge $deadline) {
                throw 'Timed out waiting for the monitor fixture observations.'
            }
            Start-Sleep -Milliseconds 20
        }
    } finally {
        $monitor.Stop()
        $monitor.Dispose()
    }
}

$pwsh = (Get-Process -Id $PID).Path
try {
    $fake = Join-Path $directory 'fake-monitor-command.ps1'
    $fakeScript = @'
$ErrorActionPreference = 'Stop'
$directory = $env:GRATE_MONITOR_TEST_DIRECTORY
$tool = $args[0]
$arguments = @($args | Select-Object -Skip 1)
$record = [pscustomobject]@{
    Tool = $tool
    Arguments = $arguments
    Pid = $PID
}
$recordPath = Join-Path $directory ([guid]::NewGuid().ToString('N') + '.json')
$record | ConvertTo-Json -Depth 10 -Compress |
    Set-Content -LiteralPath $recordPath -Encoding utf8NoBOM -NoNewline

if ($tool -ne 'docker') {
    "$tool fixture output"
    exit 0
}
switch ($arguments[0]) {
    'events' {
        [IO.File]::WriteAllText((Join-Path $directory 'events.pid'), [string]$PID)
        if ($env:GRATE_MONITOR_TEST_RESOURCE_STALL) {
            while ($true) {
                Start-Sleep -Seconds 10
            }
        }
        ('b' * 64) + ' 0 postgres:17'
        ('c' * 64) + ' 1 unrelated:latest'
        ('d' * 64) + ' 1 postgres:17 unexpected-field'
        ('a' * 64) + ' 137 postgres:17'
        [Console]::Out.Flush()
        if ($env:GRATE_MONITOR_TEST_CLOSE_EVENTS) {
            [Console]::Error.WriteLine('fixture stream ended')
            exit 3
        }
        while ($true) {
            Start-Sleep -Seconds 10
        }
    }
    'inspect' {
        if ($arguments[2].Contains('.Config') -or $arguments[2].Contains('.Source')) {
            throw 'Unsafe inspect template.'
        }
        if ($env:GRATE_MONITOR_TEST_FAIL_INSPECTION) {
            [Console]::Error.WriteLine('fixture container removed')
            exit 9
        }
        if ($env:GRATE_MONITOR_TEST_INVALID_INSPECTION) {
            'invalid inspection JSON'
            break
        }
        '{"state":{"exitCode":137,"oomKilled":true,"startedAt":"2026-11-07T22:24:18.123456789Z","finishedAt":"2026-11-07T22:24:19.987654321Z"}}'
    }
    'logs' {
        'fixture database crash log'
    }
    'ps' {
        if ($env:GRATE_MONITOR_TEST_RESOURCE_STALL) {
            [IO.File]::WriteAllText((Join-Path $directory 'resource-stall.pid'), [string]$PID)
            Start-Sleep -Seconds 60
        }
        'fixture resource output'
    }
    'hang' {
        $info = [Diagnostics.ProcessStartInfo]::new((Get-Process -Id $PID).Path)
        $info.ArgumentList.Add('-NoProfile')
        $info.ArgumentList.Add('-Command')
        $info.ArgumentList.Add('Start-Sleep -Seconds 60')
        $child = [Diagnostics.Process]::Start($info)
        [IO.File]::WriteAllText((Join-Path $directory 'child.pid'), [string]$child.Id)
        Start-Sleep -Seconds 60
    }
    default {
        'fixture resource output'
    }
}
'@
    Set-Content -LiteralPath $fake -Value $fakeScript -Encoding utf8NoBOM -NoNewline

    $commands = @{}
    foreach ($tool in @('docker', 'free', 'df')) {
        $commands[$tool] = @{
            File = $pwsh
            Prefix = @('-NoLogo', '-NoProfile', '-File', $fake, $tool)
        }
    }

    $supportedImages = @(
        'mcr.microsoft.com/mssql/server:2022'
        'mcr.microsoft.com/mssql/server@sha256:abc'
        'postgres:17'
        'postgres@sha256:abc'
        'mariadb:11'
        'mariadb@sha256:abc'
        'gvenzl/oracle-free:23'
        'gvenzl/oracle-xe@sha256:abc'
    )
    foreach ($image in $supportedImages) {
        $event = ConvertFrom-MonitorEvent "$id 001 $image"
        Assert-Monitor ($event.Id -ceq $id -and $event.ExitCode -eq 1 -and $event.Image -ceq $image) "Rejected supported database image $image."
    }
    foreach ($line in @("$id 0 postgres:17", "$id 256 postgres:17", "$id -1 postgres:17", "$id 1000 postgres:17", "$id 1 unrelated:latest", "$id 1 PostgreSQL:17", "$id 1 postgres:17 extra", 'bad 1 postgres:17')) {
        Assert-Monitor ($null -eq (ConvertFrom-MonitorEvent $line)) "Accepted invalid database failure event: $line"
    }
    Write-Host 'PASS: database image allowlist, exact event fields and exit-code/id validation.'

    $output = Join-Path $directory 'results'
    $diagnostics = Join-Path $output 'container-diagnostics'
    Invoke-MonitorUntilObserved $output $commands {
        $resourcePath = Join-Path $diagnostics 'resources.log'
        if (!(Test-Path -LiteralPath $resourcePath)) {
            return $false
        }

        $resources = [string](Get-Content -LiteralPath $resourcePath -Raw)
        $sampleCount = [regex]::Matches($resources, 'free fixture output').Count
        $logs = @(Get-ChildItem -LiteralPath $diagnostics -Filter 'container.log' -Recurse)
        $hasCrashLog = $logs.Count -eq 1 -and
            ([string](Get-Content -LiteralPath $logs[0].FullName -Raw)).Contains('fixture database crash log')
        return $resources.Contains('::endgroup::') -and $sampleCount -ge 2 -and $hasCrashLog
    }

    $captures = @(Get-ChildItem -LiteralPath $diagnostics -Directory)
    Assert-Monitor ($captures.Count -eq 1) 'Only the failed, allowlisted database event may be captured.'
    $capture = $captures[0].FullName
    Assert-Monitor ([IO.File]::ReadAllText("$capture/event.txt").Contains('exitCode=137 image=postgres:17')) 'Failure event metadata is missing.'
    $inspectionJson = Get-Content -LiteralPath "$capture/inspect.json" -Raw
    $inspection = $inspectionJson | ConvertFrom-Json
    Assert-Monitor ($inspection.state.oomKilled -eq $true -and $inspection.state.exitCode -eq 137) 'Inspection object fields were not retained.'
    Assert-Monitor ($inspectionJson.Contains('2026-11-07T22:24:18.123456789Z') -and $inspectionJson.Contains('2026-11-07T22:24:19.987654321Z')) 'Inspection must preserve Docker timestamp strings exactly.'
    Assert-Monitor ([IO.File]::ReadAllText("$capture/container.log").Contains('fixture database crash log')) 'Database crash log was not retained.'
    $resources = [IO.File]::ReadAllText((Join-Path $diagnostics 'resources.log'))
    Assert-Monitor ($resources.Contains('free fixture output') -and $resources.Contains('df fixture output') -and $resources.Contains('::endgroup::')) 'Immediate resource sample is missing or incomplete.'
    $records = @(Get-ChildItem -LiteralPath $directory -Filter '*.json' | ForEach-Object {
            Get-Content -LiteralPath $_.FullName -Raw | ConvertFrom-Json -AsHashtable
    })
    Assert-Monitor (@($records | Where-Object Tool -CEQ 'free').Count -ge 2) 'Resource sampling must repeat while the event stream remains open.'
    foreach ($record in $records) {
        Assert-Monitor ($null -eq (Get-Process -Id $record.Pid -ErrorAction SilentlyContinue)) 'Monitor cleanup left a native subprocess running.'
    }
    $inspect = @($records | Where-Object {
            $_.Tool -ceq 'docker' -and $_.Arguments[0] -ceq 'inspect'
    })
    Assert-Monitor ($inspect.Count -eq 1) 'Unexpected inspection commands.'
    $template = $inspect[0].Arguments[2]
    foreach ($field in @('$i', '$mount', '.State.OOMKilled', '.HostConfig.Memory')) {
        Assert-Monitor ($template.Contains($field)) "Inspect template lost its literal field: $field"
    }
    foreach ($privateField in @('.Config', '.Source')) {
        Assert-Monitor (!$template.Contains($privateField)) "Inspect template must exclude private field: $privateField"
    }
    $eventPid = [int][IO.File]::ReadAllText((Join-Path $directory 'events.pid'))
    Assert-Monitor ($null -eq (Get-Process -Id $eventPid -ErrorAction SilentlyContinue)) 'Event subprocess was orphaned.'
    Write-Host 'PASS: concurrent event/resources capture, explicit safe inspection, logs and event-process cleanup.'

    $env:GRATE_MONITOR_TEST_FAIL_INSPECTION = '1'
    Save-MonitorFailure @{
        Id = $id
        ExitCode = 1
        Image = 'postgres:17'
    } $diagnostics $commands
    $failedCapture = Get-ChildItem -LiteralPath $diagnostics -Directory | Sort-Object Name | Select-Object -Last 1
    Assert-Monitor ([IO.File]::ReadAllText((Join-Path $failedCapture.FullName 'inspect-error.txt')).Contains('failed or timed out')) 'Failed inspection needs diagnostic context.'
    Assert-Monitor ([IO.File]::ReadAllText((Join-Path $failedCapture.FullName 'container.log')).Contains('fixture database crash log')) 'Inspection failure must not prevent logs.'
    Write-Host 'PASS: missing/removed container inspection remains diagnostic and does not suppress logs.'

    $env:GRATE_MONITOR_TEST_FAIL_INSPECTION = ''
    $env:GRATE_MONITOR_TEST_INVALID_INSPECTION = '1'
    Save-MonitorFailure @{
        Id = $id
        ExitCode = 1
        Image = 'postgres:17'
    } $diagnostics $commands

    $invalidCapture = Get-ChildItem -LiteralPath $diagnostics -Directory | Sort-Object Name | Select-Object -Last 1
    $inspectionError = Get-Content -LiteralPath (Join-Path $invalidCapture.FullName 'inspect-error.txt') -Raw
    $containerLog = Get-Content -LiteralPath (Join-Path $invalidCapture.FullName 'container.log') -Raw
    Assert-Monitor ($inspectionError.Contains('invalid JSON')) 'Malformed inspection JSON needs diagnostic context.'
    Assert-Monitor ($containerLog.Contains('fixture database crash log')) 'Malformed inspection JSON must not prevent log capture.'
    $env:GRATE_MONITOR_TEST_INVALID_INSPECTION = ''
    Write-Host 'PASS: malformed inspection JSON remains diagnostic and does not suppress logs.'

    $result = Invoke-MonitorCommand $commands docker @('hang') 1.5
    Assert-Monitor ($result.TimedOut -and $result.ExitCode -ne 0) 'Native timeout must stop a hanging command.'
    Assert-Monitor ($null -eq (Get-Process -Id $result.ProcessId -ErrorAction SilentlyContinue)) 'Timed-out native process survived.'
    $childPid = [int][IO.File]::ReadAllText((Join-Path $directory 'child.pid'))
    Assert-Monitor ($null -eq (Get-Process -Id $childPid -ErrorAction SilentlyContinue)) 'Timed-out native descendant survived.'
    Write-Host 'PASS: bounded native command and descendant-process cleanup.'

    $env:GRATE_MONITOR_TEST_RESOURCE_STALL = '1'
    $streamingDirectory = Join-Path $directory 'interrupted-sample'
    $monitorShell = [PowerShell]::Create()
    try {
        $monitorScript = {
            param($Helper, $Directory, $Commands)

            . $Helper
            Invoke-ContainerMonitor $Directory -Commands $Commands -CommandTimeoutSeconds 3
        }
        $null = $monitorShell.AddScript($monitorScript.ToString())
        $null = $monitorShell.AddArgument($script:MonitorHelperPath)
        $null = $monitorShell.AddArgument($streamingDirectory)
        $null = $monitorShell.AddArgument($commands)
        $monitorResult = $monitorShell.BeginInvoke()
        $deadline = [DateTimeOffset]::UtcNow.AddSeconds(15)
        $stallPidPath = Join-Path $directory 'resource-stall.pid'
        while (!(Test-Path -LiteralPath $stallPidPath) -and !$monitorResult.IsCompleted -and [DateTimeOffset]::UtcNow -lt $deadline) {
            Start-Sleep -Milliseconds 20
        }
        Assert-Monitor (Test-Path -LiteralPath $stallPidPath) 'Fixture did not reach the deliberately stalled Docker resource command.'
        $resourceLog = Join-Path $streamingDirectory 'container-diagnostics/resources.log'
        Assert-Monitor (Test-Path -LiteralPath $resourceLog) 'Host metrics must be saved before the Docker resource command completes.'
        $partialSample = [IO.File]::ReadAllText($resourceLog)
        Assert-Monitor ($partialSample.Contains('free fixture output') -and $partialSample.Contains('df fixture output')) 'Already captured host metrics must survive an interrupted resource sample.'
    } finally {
        $monitorShell.Stop()
        $monitorShell.Dispose()
        $env:GRATE_MONITOR_TEST_RESOURCE_STALL = ''
    }
    foreach ($pidPath in @('events.pid', 'resource-stall.pid')) {
        $stoppedPid = [int][IO.File]::ReadAllText((Join-Path $directory $pidPath))
        Assert-Monitor ($null -eq (Get-Process -Id $stoppedPid -ErrorAction SilentlyContinue)) 'Interrupted monitor left an event or resource subprocess running.'
    }
    Assert-Monitor ([IO.File]::ReadAllText($resourceLog).Contains('df fixture output')) 'Monitor teardown discarded the partial host-resource log.'
    Write-Host 'PASS: interrupted Docker resource sample retains immediate host metrics and cleans native workers.'

    $env:GRATE_MONITOR_TEST_CLOSE_EVENTS = '1'
    Invoke-ContainerMonitor (Join-Path $directory 'closed-stream') -DurationSeconds 3 -Commands $commands
    Assert-Monitor ([IO.File]::ReadAllText((Join-Path $directory 'closed-stream/container-diagnostics/events-error.txt')).Contains('fixture stream ended')) 'Event failure stderr must be retained.'
    Assert-Monitor (Test-Path -LiteralPath (Join-Path $directory 'closed-stream/container-diagnostics/resources.log')) 'Resource sampling must continue after event-stream failure.'
    Write-Host 'PASS: event stream failure retains errors while resource sampling continues.'
} finally {
    $env:GRATE_MONITOR_TEST_DIRECTORY = $oldDirectory
    $env:GRATE_MONITOR_TEST_FAIL_INSPECTION = $oldFailInspection
    $env:GRATE_MONITOR_TEST_CLOSE_EVENTS = $oldCloseEvents
    $env:GRATE_MONITOR_TEST_RESOURCE_STALL = $oldResourceStall
    $env:GRATE_MONITOR_TEST_INVALID_INSPECTION = $oldInvalidInspection
    Remove-Item -LiteralPath $directory -Recurse -Force
}
