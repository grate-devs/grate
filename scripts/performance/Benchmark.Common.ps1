Set-StrictMode -Version Latest

function Get-DirectoryBytes {
    param(
        [Parameter(Mandatory)][string] $Path
    )

    if (!(Test-Path -LiteralPath $Path)) {
        return [long] 0
    }
    $total = [long] 0
    foreach ($file in Get-ChildItem -LiteralPath $Path -File -Recurse -Force) {
        $total += $file.Length
    }
    return $total
}

function New-BenchmarkFixtures {
    param(
        [Parameter(Mandatory)][string] $Root,
        [ValidateRange(1, 10000)][int] $SmallScriptCount = 100,
        [ValidateRange(1, 1000000)][int] $LargeRowCount = 10000
    )

    if (Test-Path -LiteralPath $Root) {
        throw "Fixture directory already exists: $Root"
    }
    foreach ($name in @('small', 'large', 'failure')) {
        New-Item -ItemType Directory -Path (Join-Path $Root "$name/up") -Force | Out-Null
    }

    $small = Join-Path $Root 'small/up'
    Set-Content -LiteralPath (Join-Path $small '00000_create.sql') -Encoding utf8NoBOM -Value @'
CREATE TABLE benchmark_values(id INTEGER PRIMARY KEY, value TEXT NOT NULL);
CREATE TABLE benchmark_engine AS SELECT sqlite_version() AS version;
'@
    $names = [Collections.Generic.List[string]]::new()
    $names.Add('00000_create.sql')
    for ($index = 1; $index -le $SmallScriptCount; $index++) {
        $name = '{0:D5}_insert.sql' -f $index
        $names.Add($name)
        Set-Content -LiteralPath (Join-Path $small $name) -Encoding utf8NoBOM -Value "INSERT INTO benchmark_values VALUES ($index, 'Grüß 世界 $index');"
    }

    # A substantial deterministic script exercises reading, hashing and splitting as
    # well as actual database writes. It is deliberately not an in-memory microbenchmark.
    $largeLines = [Collections.Generic.List[string]]::new()
    $largeLines.Add('CREATE TABLE benchmark_values(id INTEGER PRIMARY KEY, value TEXT NOT NULL);')
    $largeLines.Add('CREATE TABLE benchmark_engine AS SELECT sqlite_version() AS version;')
    for ($index = 1; $index -le $LargeRowCount; $index++) {
        $largeLines.Add("INSERT INTO benchmark_values VALUES ($index, 'Grüß 世界 $index');")
    }
    Set-Content -LiteralPath (Join-Path $Root 'large/up/00001_large.sql') -Encoding utf8NoBOM -Value $largeLines

    Set-Content -LiteralPath (Join-Path $Root 'failure/up/00001_before.sql') -Encoding utf8NoBOM -Value @'
CREATE TABLE benchmark_before(value INTEGER NOT NULL);
INSERT INTO benchmark_before VALUES (42);
'@
    Set-Content -LiteralPath (Join-Path $Root 'failure/up/00002_failure.sql') -Encoding utf8NoBOM -Value 'INSERT INTO benchmark_missing VALUES (1);'
    Set-Content -LiteralPath (Join-Path $Root 'failure/up/00003_after.sql') -Encoding utf8NoBOM -Value 'CREATE TABLE benchmark_after(value INTEGER);'

    return [pscustomobject] @{
        SmallRoot = Join-Path $Root 'small'
        LargeRoot = Join-Path $Root 'large'
        FailureRoot = Join-Path $Root 'failure'
        SmallScriptNames = $names.ToArray()
        SmallRows = $SmallScriptCount
        LargeRows = $LargeRowCount
    }
}

function Invoke-SqliteQuery {
    param(
        [Parameter(Mandatory)][string] $Database,
        [Parameter(Mandatory)][string] $Sql
    )

    $output = & sqlite3 -readonly -batch -noheader $Database $Sql
    if ($LASTEXITCODE -ne 0) {
        throw "SQLite assertion query failed with exit code $LASTEXITCODE."
    }
    return @($output) -join "`n"
}

function Assert-BenchmarkEqual {
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string] $Actual,
        [Parameter(Mandatory)][AllowEmptyString()][string] $Expected,
        [Parameter(Mandatory)][string] $Context
    )

    if ($Actual -cne $Expected) {
        throw "${Context}: expected '$Expected', observed '$Actual'."
    }
}

function Assert-BenchmarkStartup {
    param(
        [Parameter(Mandatory)][ValidateSet('help', 'version-parse-error')][string] $Workload,
        [Parameter(Mandatory)][AllowEmptyString()][string] $Output,
        [string[]] $Providers = @()
    )

    if ($Workload -eq 'help') {
        foreach ($option in @('--connectionstring', '--databasetype', '--silent')) {
            if (!$Output.Contains($option, [StringComparison]::Ordinal)) {
                throw "CLI help is missing expected option $option."
            }
        }
        foreach ($provider in $Providers) {
            if ($Output -notmatch [Regex]::Escape($provider)) {
                throw "CLI help is missing expected provider $provider."
            }
        }
    }
    elseif ($Output -notmatch '(?is)(required.*--version|--version.*required)') {
        throw 'CLI version argument did not produce the expected required-argument error.'
    }
}

function Assert-BenchmarkDatabase {
    param(
        [Parameter(Mandatory)][string] $Database,
        [Parameter(Mandatory)][ValidateSet('small', 'large', 'failure')][string] $Fixture,
        [Parameter(Mandatory)] $Fixtures
    )

    Assert-BenchmarkEqual (Invoke-SqliteQuery $Database 'PRAGMA integrity_check;') 'ok' 'Database integrity'
    if ($Fixture -eq 'failure') {
        Assert-BenchmarkEqual (Invoke-SqliteQuery $Database 'SELECT value FROM benchmark_before;') '42' 'Previously committed effect'
        Assert-BenchmarkEqual (Invoke-SqliteQuery $Database "SELECT count(*) FROM sqlite_master WHERE name = 'benchmark_after';") '0' 'Subsequent script must not execute'
        Assert-BenchmarkEqual (Invoke-SqliteQuery $Database 'SELECT script_name FROM grate_ScriptsRun ORDER BY id;') '00001_before.sql' 'Failure history excludes failed and subsequent scripts'
        Assert-BenchmarkEqual (Invoke-SqliteQuery $Database "SELECT count(*) FROM grate_ScriptsRunErrors WHERE script_name = '00002_failure.sql' AND length(error_message) > 0;") '1' 'Error history'
        return
    }

    $rows = $Fixtures.SmallRows
    $names = @($Fixtures.SmallScriptNames)
    if ($Fixture -eq 'large') {
        $rows = $Fixtures.LargeRows
        $names = @('00001_large.sql')
    }
    $sum = [long] $rows * ($rows + 1) / 2
    Assert-BenchmarkEqual (Invoke-SqliteQuery $Database 'SELECT count(*) || ''|'' || sum(id) FROM benchmark_values;') "$rows|$sum" 'Migration data'
    Assert-BenchmarkEqual (Invoke-SqliteQuery $Database "SELECT count(*) FROM benchmark_values WHERE value = 'Grüß 世界 ' || id;") "$rows" 'UTF-8 data'
    Assert-BenchmarkEqual (Invoke-SqliteQuery $Database 'SELECT script_name FROM grate_ScriptsRun ORDER BY id;') ($names -join "`n") 'Ordered migration history'
    Assert-BenchmarkEqual (Invoke-SqliteQuery $Database 'SELECT count(*) FROM grate_ScriptsRun WHERE one_time_script = 1 AND length(text_hash) > 0 AND length(text_of_script) > 0;') "$($names.Count)" 'History hashes and SQL text'
    Assert-BenchmarkEqual (Invoke-SqliteQuery $Database 'SELECT count(*) FROM grate_ScriptsRunErrors;') '0' 'Successful migration error history'
}

function Get-BenchmarkHistory {
    param(
        [Parameter(Mandatory)][string] $Database
    )

    # Exact stored identities are compared across reruns, independently of the
    # implementation that computes grate's persisted hashes.
    return Invoke-SqliteQuery $Database 'SELECT id, script_name, text_hash, text_of_script, one_time_script, version_id FROM grate_ScriptsRun ORDER BY id;'
}

function Get-BenchmarkDistribution {
    param(
        [Parameter(Mandatory)][double[]] $Values
    )

    $sorted = @($Values | Sort-Object)
    if ($sorted.Count -eq 0) {
        throw 'Cannot summarize an empty measurement set.'
    }
    $median = $sorted[[int] [Math]::Floor($sorted.Count / 2)]
    if ($sorted.Count % 2 -eq 0) {
        $median = ($sorted[$sorted.Count / 2 - 1] + $median) / 2
    }
    $average = ($sorted | Measure-Object -Average).Average
    $squaredDeviation = 0.0
    foreach ($value in $sorted) {
        $squaredDeviation += [Math]::Pow($value - $average, 2)
    }
    return [pscustomobject] @{
        count = $sorted.Count
        minimum = $sorted[0]
        median = $median
        p95NearestRank = $sorted[[Math]::Ceiling(0.95 * $sorted.Count) - 1]
        maximum = $sorted[-1]
        mean = $average
        populationStandardDeviation = [Math]::Sqrt($squaredDeviation / $sorted.Count)
    }
}
