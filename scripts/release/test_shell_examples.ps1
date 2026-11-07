#!/usr/bin/env pwsh
. "$PSScriptRoot/release_common.ps1"
. "$PSScriptRoot/release_test_helpers.ps1"

$repository = Split-Path (Split-Path $PSScriptRoot)
$directory = New-TestDirectory
$pwsh = (Get-Process -Id $PID).Path
$saved = @{}
$environmentKeys = @('PATH', 'GRATE_EXAMPLE_EVENTS', 'GRATE_INITIAL_EXIT', 'GRATE_SECOND_EXIT', 'GRATE_COMPOSE_FAILURE')
foreach ($key in $environmentKeys) {
    $saved[$key] = [Environment]::GetEnvironmentVariable($key)
}

try {
    $events = "$directory/events.jsonl"
    $env:GRATE_EXAMPLE_EVENTS = $events
    $fakeGrateScript = @'
$calls = @(
    if (Test-Path -LiteralPath $env:GRATE_EXAMPLE_EVENTS) {
        Get-Content -LiteralPath $env:GRATE_EXAMPLE_EVENTS
    }
)
$filesArgument = @($args | Where-Object { $_ -like '--files=*' })[0]
$files = $filesArgument.Substring('--files='.Length)
$sql = if ($calls.Count -eq 0) {
    "$files/up/01-create.sql"
} else {
    "$files/up/02-failure.sql"
}

if (!(Test-Path -LiteralPath $sql)) {
    throw 'Smoke example did not create its SQL input.'
}

$record = @{
    args = @($args)
    sql = $sql
    content = Get-Content -LiteralPath $sql -Raw
}
$json = $record | ConvertTo-Json -Compress
Add-Content -LiteralPath $env:GRATE_EXAMPLE_EVENTS -Value ($json + "`n") -NoNewline -Encoding utf8NoBOM
Write-Host "visible migration $($calls.Count)"

if ($calls.Count -eq 0) {
    exit ([int]$env:GRATE_INITIAL_EXIT)
}
exit ([int]$env:GRATE_SECOND_EXIT)
'@
    Set-Content -LiteralPath "$directory/fake grate.ps1" -Value $fakeGrateScript -NoNewline -Encoding utf8NoBOM

    Invoke-Test 'CI logging example streams both migrations and accepts only the intended exit codes' {
        $cases = @(
            @{
                InitialExit = 0
                SecondExit = 1
                Succeeds = $true
                Calls = 2
            }
            @{
                InitialExit = 4
                SecondExit = 1
                Succeeds = $false
                Calls = 1
            }
            @{
                InitialExit = 0
                SecondExit = 0
                Succeeds = $false
                Calls = 2
            }
            @{
                InitialExit = 0
                SecondExit = 2
                Succeeds = $false
                Calls = 2
            }
        )
        $arguments = @(
            '-NoLogo', '-NoProfile', '-File', "$repository/examples/ci-logging/smoke.ps1"
            '-Grate', "$directory/fake grate.ps1"
            '-CommandArguments', 'prefix with spaces'
        )

        foreach ($case in $cases) {
            [IO.File]::Delete($events)
            $env:GRATE_INITIAL_EXIT = [string]$case.InitialExit
            $env:GRATE_SECOND_EXIT = [string]$case.SecondExit
            $result = Invoke-ReleaseProcess $pwsh $arguments 30
            Assert-Equal $case.Succeeds ($result.ExitCode -eq 0) $result.ErrorText

            $records = @(Get-Content -LiteralPath $events | ConvertFrom-Json -AsHashtable)
            Assert-Equal $case.Calls $records.Count
            Assert-Equal 'prefix with spaces' $records[0].args[0]
            Assert-True ($records[0].args -ccontains '--transaction')
            Assert-True ($records[0].content.Contains('CREATE TABLE example'))
            Assert-True ($result.Text.Contains('visible migration 0'))

            if ($records.Count -eq 2) {
                Assert-True ($records[1].args -cnotcontains '--transaction')
                Assert-True ($records[1].content.Contains('missing_table') -and $result.Text.Contains('visible migration 1'))
            }

            foreach ($record in $records) {
                $sqlDirectory = Split-Path (Split-Path $record.sql)
                Assert-True (!(Test-Path -LiteralPath $sqlDirectory)) 'Temporary SQL directory must be removed on success and failure.'
            }
        }
    }

    $fakeDockerScript = @'
$record = @{
    args = @($args)
    cwd = $PWD.Path
}
$json = $record | ConvertTo-Json -Compress
Add-Content -LiteralPath $env:GRATE_EXAMPLE_EVENTS -Value ($json + "`n") -NoNewline -Encoding utf8NoBOM

if ($args[1] -ceq $env:GRATE_COMPOSE_FAILURE) {
    exit 18
}
exit 0
'@
    Set-Content -LiteralPath "$directory/docker.ps1" -Value $fakeDockerScript -NoNewline -Encoding utf8NoBOM
    $env:PATH = $directory + [IO.Path]::PathSeparator + $saved.PATH

    Invoke-Test 'Compose example uses its directory and propagates startup and shutdown failures' {
        $arguments = @('-NoLogo', '-NoProfile', '-File', "$repository/examples/docker/build-and-run.ps1")
        $expectedDirectory = [IO.Path]::GetFullPath((Join-Path $repository 'examples/docker'))

        foreach ($failure in @('', 'up', 'down')) {
            [IO.File]::Delete($events)
            $env:GRATE_COMPOSE_FAILURE = $failure
            $result = Invoke-ReleaseProcess $pwsh $arguments 30
            Assert-Equal ($failure -ceq '') ($result.ExitCode -eq 0) $result.ErrorText

            $records = @(Get-Content -LiteralPath $events | ConvertFrom-Json -AsHashtable)
            Assert-Equal @('compose', 'up', '--build') $records[0].args
            $expectedCalls = if ($failure -ceq 'up') {
                1
            } else {
                2
            }
            Assert-Equal $expectedCalls $records.Count

            foreach ($record in $records) {
                Assert-Equal $expectedDirectory $record.cwd
            }
            if ($records.Count -eq 2) {
                Assert-Equal @('compose', 'down') $records[1].args
            }
        }
    }
} finally {
    foreach ($key in $saved.Keys) {
        [Environment]::SetEnvironmentVariable($key, $saved[$key])
    }
    Remove-Item -LiteralPath $directory -Recurse -Force
}

Write-Host "PASS: $script:TestCount shell-example scenario groups."
