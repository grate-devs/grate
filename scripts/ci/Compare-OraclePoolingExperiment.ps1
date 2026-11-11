#!/usr/bin/env pwsh
param(
    [Parameter(Mandatory)]
    [string]$ResultsDirectory
)

$ErrorActionPreference = 'Stop'
function Read-OracleSuite {
    param(
        [string]$Directory
    )

    $reports = @(Get-ChildItem -LiteralPath $Directory -Filter *.trx -Recurse)
    if ($reports.Count -ne 1) {
        throw 'Require exactly one complete TRX report per variant and TFM.'
    }
    [xml]$xml = Get-Content -LiteralPath $reports[0].FullName -Raw
    $definitions = @{}
    foreach ($definition in $xml.TestRun.TestDefinitions.UnitTest) {
        $definitions[$definition.id] = $definition.TestMethod
    }
    $records = @(foreach ($result in $xml.TestRun.Results.UnitTestResult) {
        $method = $definitions[$result.testId]
        if (!$method) {
            throw 'Result has no test definition.'
        }
        $name = [string]$result.testName
        if ($method.name -ceq 'The_table_name_casings_are_converted_if_needed') {
            $name = $name.ToLowerInvariant()
        }
        @($method.className, $method.name, $name, $result.outcome) | ConvertTo-Json -Compress
    })
    $counters = $xml.TestRun.ResultSummary.Counters
    $passed = @($xml.TestRun.Results.UnitTestResult | Where-Object outcome -CEQ 'Passed').Count
    $skipped = @($xml.TestRun.Results.UnitTestResult | Where-Object outcome -CEQ 'NotExecuted').Count
    if ([int]$counters.total -ne 321 -or [int]$counters.failed -ne 0 -or
        [int]$counters.passed -ne 320 -or [int]$counters.notExecuted -ne 1 -or
        $records.Count -ne [int]$counters.total -or $passed -ne 320 -or $skipped -ne 1) {
        throw 'Incomplete suite, failed tests, or changed skips in Oracle experiment.'
    }
    return [pscustomobject]@{
        Records = @($records | Sort-Object -CaseSensitive)
        Total = [int]$counters.total
        Passed = [int]$counters.passed
        Skipped = [int]$counters.notExecuted
        TestSeconds = @($xml.TestRun.Results.UnitTestResult | ForEach-Object {
            [TimeSpan]::Parse($_.duration, [Globalization.CultureInfo]::InvariantCulture).TotalSeconds
        } | Measure-Object -Sum).Sum
        RunnerIntervalSeconds = ([DateTimeOffset]$xml.TestRun.Times.finish - [DateTimeOffset]$xml.TestRun.Times.start).TotalSeconds
    }
}

$baseline = Read-OracleSuite -Directory (Join-Path $ResultsDirectory 'baseline')
$scoped = Read-OracleSuite -Directory (Join-Path $ResultsDirectory 'scoped')
if (@(Compare-Object -ReferenceObject $baseline.Records -DifferenceObject $scoped.Records -CaseSensitive).Count -gt 0) {
    throw 'Oracle case identities/outcomes differ between baseline and scoped pooling.'
}
[pscustomobject]@{
    Baseline = $baseline | Select-Object Total,Passed,Skipped,TestSeconds,RunnerIntervalSeconds
    Scoped = $scoped | Select-Object Total,Passed,Skipped,TestSeconds,RunnerIntervalSeconds
    TestTimeChangePercent = 100 * ($scoped.TestSeconds / $baseline.TestSeconds - 1)
    IdentityComparison = 'Identical class/method/display/outcome multisets; only the existing randomized casing arguments normalized'
} | ConvertTo-Json -Depth 6 | Tee-Object -FilePath (Join-Path $ResultsDirectory 'comparison.json')
