#!/usr/bin/env pwsh
. "$PSScriptRoot/../../../scripts/release/release_common.ps1"
. "$PSScriptRoot/../../../scripts/release/release_test_helpers.ps1"

$directory = New-TestDirectory
$events = Join-Path $directory 'events.jsonl'
$wrapper = Join-Path $PSScriptRoot 'run.ps1'
$pwsh = (Get-Process -Id $PID).Path
$savedEnvironment = @{}
foreach ($name in @('PATH', 'GRATE_WRAPPER_EVENTS', 'GRATE_WRAPPER_FAIL_DRIVER', 'GRATE_WRAPPER_FAIL_CLEANUP')) {
    $savedEnvironment[$name] = [Environment]::GetEnvironmentVariable($name)
}

function Read-WrapperEvents {
    if (Test-Path -LiteralPath $events) {
        Get-Content -LiteralPath $events | ForEach-Object {
            ConvertFrom-Json -InputObject $_ -AsHashtable
        }
    }
}

function Invoke-WrapperFixture {
    param(
        [string[]]$Arguments
    )

    Remove-Item -LiteralPath $events -ErrorAction SilentlyContinue
    $command = @('-NoProfile', '-File', $wrapper) + $Arguments
    Invoke-ReleaseProcess $pwsh $command 30
}

function Assert-WrapperCleanup {
    $records = @(Read-WrapperEvents)
    $created = @($records | Where-Object { $_.tool -eq 'docker' -and $_.args[0] -eq 'network' -and $_.args[1] -eq 'create' })
    Assert-Equal 1 $created.Count
    $network = $created[0].args[2]
    $networkRemoval = @($records | Where-Object { ($_.args -join '|') -eq "network|rm|$network" })
    Assert-Equal 1 $networkRemoval.Count
    $ownedRemoval = @($records | Where-Object { ($_.args -join '|') -eq 'rm|-f|fixture-owned-runtime' })
    Assert-Equal 1 $ownedRemoval.Count
    $knownRemoval = @($records | Where-Object { $_.args[0] -eq 'rm' -and $_.args.Count -eq 6 })
    Assert-Equal 1 $knownRemoval.Count
}

try {
    $dockerFixture = @'
$record = @{
    tool = 'docker'
    args = @($args)
    sqlserver = $env:GRATE_POC_SQLSERVER
    mariadb = $env:GRATE_POC_MARIADB
} | ConvertTo-Json -Compress
Add-Content -LiteralPath $env:GRATE_WRAPPER_EVENTS -Value $record -Encoding utf8NoBOM
if ($args[0] -eq 'ps') {
    'fixture-owned-runtime'
}
if ($env:GRATE_WRAPPER_FAIL_DRIVER -and $args[0] -eq 'exec' -and ($args -join '|').Contains('verify.py')) {
    exit 23
}
if ($env:GRATE_WRAPPER_FAIL_CLEANUP -and ($args[0] -eq 'rm' -or ($args[0] -eq 'network' -and $args[1] -eq 'rm'))) {
    exit 17
}
exit 0
'@
    $pythonFixture = @'
$record = @{
    tool = 'python3'
    args = @($args)
    sqlserver = $env:GRATE_POC_SQLSERVER
    mariadb = $env:GRATE_POC_MARIADB
} | ConvertTo-Json -Compress
Add-Content -LiteralPath $env:GRATE_WRAPPER_EVENTS -Value $record -Encoding utf8NoBOM
exit 0
'@
    Set-Content -LiteralPath "$directory/docker.ps1" -Value $dockerFixture -Encoding utf8NoBOM
    Set-Content -LiteralPath "$directory/python3.ps1" -Value $pythonFixture -Encoding utf8NoBOM
    $env:PATH = $directory + [IO.Path]::PathSeparator + $savedEnvironment['PATH']
    $env:GRATE_WRAPPER_EVENTS = $events
    $env:GRATE_WRAPPER_FAIL_DRIVER = ''
    $env:GRATE_WRAPPER_FAIL_CLEANUP = ''
    $output = 'artifacts/wrapper fixture ' + [Guid]::NewGuid().ToString('N')

    Invoke-Test 'CLI remains the default and forwards a spaced output path' {
        $result = Invoke-WrapperFixture @('-OutputDirectory', $output)
        Assert-Equal 0 $result.ExitCode $result.ErrorText
        $drivers = @(Read-WrapperEvents | Where-Object { $_.tool -eq 'docker' -and $_.args[0] -eq 'exec' -and ($_.args -join '|').Contains('verify.py') })
        Assert-Equal 1 $drivers.Count
        Assert-Equal $output $drivers[0].args[-1]
        Assert-True ($drivers[0].sqlserver.Contains('Database={database}'))
        Assert-True ($drivers[0].mariadb.Contains('Database={database}'))
        $hostDrivers = @(Read-WrapperEvents | Where-Object tool -EQ 'python3')
        Assert-Equal 0 $hostDrivers.Count
        Assert-WrapperCleanup
    }

    Invoke-Test 'packaging selects the existing host driver and native package builder' {
        $result = Invoke-WrapperFixture @('-OutputDirectory', $output, '-Mode', 'packaging')
        Assert-Equal 0 $result.ExitCode $result.ErrorText
        $records = @(Read-WrapperEvents)
        $drivers = @($records | Where-Object tool -EQ 'python3')
        Assert-Equal 1 $drivers.Count
        Assert-Equal 'docs/design/slim-distributions-poc/verify-packaging.py' $drivers[0].args[0]
        Assert-Equal @('--output', $output) @($drivers[0].args[1..2])
        Assert-True ($drivers[0].sqlserver.Contains('Database={database}'))
        Assert-True ($drivers[0].mariadb.Contains('Database={database}'))
        $packagers = @($records | Where-Object { $_.tool -eq 'docker' -and $_.args[0] -eq 'run' -and ($_.args -join '|').Contains('sdk:10.0@sha256:747cbade') })
        Assert-Equal 1 $packagers.Count
        Assert-True ($packagers[0].args -notcontains '--platform')
        Assert-WrapperCleanup
    }

    Invoke-Test 'driver failure survives failing cleanup commands' {
        $env:GRATE_WRAPPER_FAIL_DRIVER = '1'
        $env:GRATE_WRAPPER_FAIL_CLEANUP = '1'
        try {
            $result = Invoke-WrapperFixture @('-OutputDirectory', $output)
            Assert-Equal 23 $result.ExitCode $result.ErrorText
            Assert-WrapperCleanup
        } finally {
            $env:GRATE_WRAPPER_FAIL_DRIVER = ''
            $env:GRATE_WRAPPER_FAIL_CLEANUP = ''
        }
    }

    Invoke-Test 'invalid parameters create no Docker resources' {
        foreach ($arguments in @(@('-Mode', 'invalid'), @('-OutputDirectory', $directory))) {
            $result = Invoke-WrapperFixture $arguments
            Assert-True ($result.ExitCode -ne 0)
            Assert-Equal 0 @(Read-WrapperEvents).Count
        }
    }
} finally {
    foreach ($name in $savedEnvironment.Keys) {
        [Environment]::SetEnvironmentVariable($name, $savedEnvironment[$name])
    }
    Remove-Item -LiteralPath $directory -Recurse -Force
}
Write-Host "PASS: $script:TestCount PoC wrapper fixtures."
