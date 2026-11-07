#!/usr/bin/env pwsh
. "$PSScriptRoot/release_common.ps1"
. "$PSScriptRoot/release_test_helpers.ps1"
$repository = Split-Path (Split-Path $PSScriptRoot)
$directory = New-TestDirectory
$pwsh = (Get-Process -Id $PID).Path
$saved = @{}
foreach ($key in @('PATH','GRATE_EXAMPLE_EVENTS','GRATE_INITIAL_EXIT','GRATE_SECOND_EXIT','GRATE_COMPOSE_FAILURE')) { $saved[$key] = [Environment]::GetEnvironmentVariable($key) }
try {
    $events = "$directory/events.jsonl"
    $env:GRATE_EXAMPLE_EVENTS = $events
    [IO.File]::WriteAllText("$directory/fake grate.ps1", @'
$calls = @(if (Test-Path -LiteralPath $env:GRATE_EXAMPLE_EVENTS) { Get-Content -LiteralPath $env:GRATE_EXAMPLE_EVENTS })
$files = @($args | Where-Object { $_ -like '--files=*' })[0].Substring('--files='.Length)
$sql = if ($calls.Count -eq 0) { "$files/up/01-create.sql" } else { "$files/up/02-failure.sql" }
if (!(Test-Path -LiteralPath $sql)) { throw 'Smoke example did not create its SQL input.' }
[IO.File]::AppendAllText($env:GRATE_EXAMPLE_EVENTS, ((@{args=@($args);sql=$sql;content=[IO.File]::ReadAllText($sql)} | ConvertTo-Json -Compress) + "`n"))
Write-Host "visible migration $($calls.Count)"
if ($calls.Count -eq 0) { exit ([int]$env:GRATE_INITIAL_EXIT) }
exit ([int]$env:GRATE_SECOND_EXIT)
'@)
    Invoke-Test 'CI logging example streams both migrations and accepts only the intended exit codes' {
        foreach ($case in @(@(0,1,$true,2),@(4,1,$false,1),@(0,0,$false,2),@(0,2,$false,2))) {
            [IO.File]::Delete($events)
            $env:GRATE_INITIAL_EXIT=[string]$case[0]; $env:GRATE_SECOND_EXIT=[string]$case[1]
            $result = Invoke-ReleaseProcess $pwsh @('-NoLogo','-NoProfile','-File',"$repository/examples/ci-logging/smoke.ps1",'-Grate',"$directory/fake grate.ps1",'-CommandArguments','prefix with spaces') 30
            Assert-Equal $case[2] ($result.ExitCode -eq 0) $result.ErrorText
            $records=@(Get-Content -LiteralPath $events | ConvertFrom-Json -AsHashtable)
            Assert-Equal $case[3] $records.Count
            Assert-Equal 'prefix with spaces' $records[0].args[0]
            Assert-True ($records[0].args -ccontains '--transaction')
            Assert-True ($records[0].content.Contains('CREATE TABLE example'))
            Assert-True ($result.Text.Contains('visible migration 0'))
            if ($records.Count -eq 2) {
                Assert-True ($records[1].args -cnotcontains '--transaction')
                Assert-True ($records[1].content.Contains('missing_table') -and $result.Text.Contains('visible migration 1'))
            }
            foreach ($record in $records) { Assert-True (!(Test-Path -LiteralPath (Split-Path (Split-Path $record.sql)))) 'Temporary SQL directory must be removed on success and failure.' }
        }
    }
    [IO.File]::WriteAllText("$directory/docker.ps1", @'
[IO.File]::AppendAllText($env:GRATE_EXAMPLE_EVENTS, ((@{args=@($args);cwd=$PWD.Path} | ConvertTo-Json -Compress) + "`n"))
if ($args[1] -ceq $env:GRATE_COMPOSE_FAILURE) { exit 18 }
exit 0
'@)
    $env:PATH = $directory + [IO.Path]::PathSeparator + $saved.PATH
    Invoke-Test 'Compose example uses its directory and propagates startup and shutdown failures' {
        foreach ($failure in @('','up','down')) {
            [IO.File]::Delete($events); $env:GRATE_COMPOSE_FAILURE=$failure
            $result = Invoke-ReleaseProcess $pwsh @('-NoLogo','-NoProfile','-File',"$repository/examples/docker/build-and-run.ps1") 30
            Assert-Equal ($failure -ceq '') ($result.ExitCode -eq 0) $result.ErrorText
            $records=@(Get-Content -LiteralPath $events | ConvertFrom-Json -AsHashtable)
            Assert-Equal @('compose','up','--build') $records[0].args
            Assert-Equal $(if ($failure -ceq 'up') {1} else {2}) $records.Count
            foreach ($record in $records) { Assert-Equal ([IO.Path]::GetFullPath((Join-Path $repository 'examples/docker'))) $record.cwd }
            if ($records.Count -eq 2) { Assert-Equal @('compose','down') $records[1].args }
        }
    }
} finally {
    foreach ($key in $saved.Keys) { [Environment]::SetEnvironmentVariable($key,$saved[$key]) }
    Remove-Item -LiteralPath $directory -Recurse -Force
}
Write-Host "PASS: $script:TestCount shell-example scenario groups."
