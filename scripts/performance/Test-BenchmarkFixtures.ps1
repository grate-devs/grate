#!/usr/bin/env pwsh
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
. (Join-Path $PSScriptRoot 'Benchmark.Common.ps1')

$root = Join-Path ([IO.Path]::GetTempPath()) ('grate-benchmark-tests-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $root | Out-Null

function Invoke-TestSql {
    param(
        [Parameter(Mandatory)][string] $Database,
        [Parameter(Mandatory)][string] $Sql
    )

    & sqlite3 -batch $Database $Sql | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "Test SQL failed with exit code $LASTEXITCODE."
    }
}

function Assert-Rejected {
    param(
        [Parameter(Mandatory)][scriptblock] $Action,
        [Parameter(Mandatory)][string] $Message
    )

    $rejected = $false
    try {
        & $Action
    }
    catch {
        if ($_.Exception.Message -notlike "*$Message*") {
            throw
        }
        $rejected = $true
    }
    if (!$rejected) {
        throw "Wrong behavior was accepted: $Message"
    }
}

try {
    $fixtures = New-BenchmarkFixtures -Root (Join-Path $root 'fixtures') -SmallScriptCount 3 -LargeRowCount 7
    $second = New-BenchmarkFixtures -Root (Join-Path $root 'second') -SmallScriptCount 3 -LargeRowCount 7
    foreach ($file in Get-ChildItem -LiteralPath (Join-Path $root 'fixtures') -File -Recurse) {
        $relative = [IO.Path]::GetRelativePath((Join-Path $root 'fixtures'), $file.FullName)
        $other = Join-Path (Join-Path $root 'second') $relative
        Assert-BenchmarkEqual (Get-FileHash -LiteralPath $file.FullName).Hash (Get-FileHash -LiteralPath $other).Hash "Deterministic fixture $relative"
    }
    Assert-Rejected { New-BenchmarkFixtures -Root (Join-Path $root 'fixtures') } 'already exists'

    foreach ($fixtureName in @('small', 'large')) {
        $database = Join-Path $root "$fixtureName.db"
        $scripts = Join-Path $root "fixtures/$fixtureName/up"
        # Direct SQLite execution tests independently known fixture effects. It
        # does not replace the harness's actual packaged-CLI checks.
        Invoke-TestSql $database @'
CREATE TABLE grate_ScriptsRun(id INTEGER PRIMARY KEY, script_name TEXT, text_hash TEXT, text_of_script TEXT, one_time_script INTEGER, version_id INTEGER);
CREATE TABLE grate_ScriptsRunErrors(script_name TEXT, error_message TEXT);
'@
        foreach ($file in Get-ChildItem -LiteralPath $scripts -File | Sort-Object Name) {
            Invoke-TestSql $database (Get-Content -LiteralPath $file.FullName -Raw)
            Invoke-TestSql $database "INSERT INTO grate_ScriptsRun(script_name, text_hash, text_of_script, one_time_script, version_id) VALUES ('$($file.Name)', 'known-hash', 'known-sql', 1, 1);"
        }
        Assert-BenchmarkDatabase -Database $database -Fixture $fixtureName -Fixtures $fixtures
    }

    $smallDatabase = Join-Path $root 'small.db'
    Invoke-TestSql $smallDatabase "UPDATE benchmark_values SET value = 'ASCII replacement' WHERE id = 1;"
    Assert-Rejected { Assert-BenchmarkDatabase $smallDatabase 'small' $fixtures } 'UTF-8 data'
    Invoke-TestSql $smallDatabase "UPDATE benchmark_values SET value = 'Grüß 世界 1' WHERE id = 1;"
    Invoke-TestSql $smallDatabase "UPDATE grate_ScriptsRun SET text_hash = '' WHERE id = 1;"
    Assert-Rejected { Assert-BenchmarkDatabase $smallDatabase 'small' $fixtures } 'History hashes and SQL text'
    Invoke-TestSql $smallDatabase "UPDATE grate_ScriptsRun SET text_hash = 'known-hash', script_name = 'wrong-order.sql' WHERE id = 1;"
    Assert-Rejected { Assert-BenchmarkDatabase $smallDatabase 'small' $fixtures } 'Ordered migration history'

    $failureDatabase = Join-Path $root 'failure.db'
    Invoke-TestSql $failureDatabase (Get-Content -LiteralPath (Join-Path $fixtures.FailureRoot 'up/00001_before.sql') -Raw)
    Invoke-TestSql $failureDatabase @'
CREATE TABLE grate_ScriptsRun(id INTEGER PRIMARY KEY, script_name TEXT);
INSERT INTO grate_ScriptsRun VALUES (1, '00001_before.sql');
CREATE TABLE grate_ScriptsRunErrors(script_name TEXT, error_message TEXT);
INSERT INTO grate_ScriptsRunErrors VALUES ('00002_failure.sql', 'no such table');
'@
    Assert-BenchmarkDatabase $failureDatabase 'failure' $fixtures
    Invoke-TestSql $failureDatabase 'CREATE TABLE benchmark_after(value INTEGER);'
    Assert-Rejected { Assert-BenchmarkDatabase $failureDatabase 'failure' $fixtures } 'Subsequent script must not execute'

    $distribution = Get-BenchmarkDistribution @(1, 2, 3, 4)
    Assert-BenchmarkEqual "$($distribution.median)" '2.5' 'Even sample median'
    Assert-BenchmarkEqual "$($distribution.p95NearestRank)" '4' 'Nearest rank p95'
    Assert-BenchmarkEqual "$($distribution.count)" '4' 'Distribution count'
    Assert-BenchmarkEqual "$((Get-BenchmarkDistribution @(3, 1, 2)).median)" '2' 'Odd sample median'

    Assert-BenchmarkStartup -Workload 'help' -Output '--connectionstring --databasetype --silent sqlite' -Providers @('sqlite')
    Assert-BenchmarkStartup -Workload 'version-parse-error' -Output "Required argument missing for option: '--version'."
    Assert-Rejected { Assert-BenchmarkStartup -Workload 'help' -Output '' } 'missing expected option'
    Assert-Rejected { Assert-BenchmarkStartup -Workload 'version-parse-error' -Output '' } 'expected required-argument error'
    Assert-Rejected { Assert-BenchmarkStartup -Workload 'help' -Output '--connectionstring --databasetype --silent' -Providers @('oracle') } 'missing expected provider oracle'

    Write-Host 'PASS: deterministic SQL effects, Unicode, ordered history, hashes, failure-stop assertions, startup output and distributions; wrong histories/data/continued execution and blank startup output are rejected.'
}
finally {
    Remove-Item -LiteralPath $root -Recurse -Force
}
