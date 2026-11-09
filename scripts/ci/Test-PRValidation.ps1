#!/usr/bin/env pwsh
$ErrorActionPreference = 'Stop'
$gate = Join-Path $PSScriptRoot 'Assert-PRValidation.ps1'
$script:passed = 0

function New-Fixture {
    # A contract fixture, not a call to the production inventory. Matrix names
    # match the checks GitHub emits, including Windows provider filter arguments.
    $names = @('Build', 'NuGet libraries and installed tool', 'PR validation policy')
    foreach ($category in @('Basic_tests', 'SqlServer', 'SqlServerCaseSensitive', 'PostgreSQL', 'MariaDB', 'Sqlite', 'Oracle')) {
        $names += "Run tests (ubuntu-latest, $category)"
    }
    $names += 'Run tests (windows-latest, Basic_tests)', 'Run tests (windows-latest, Sqlite)'
    foreach ($category in @('SqlServer', 'SqlServerCaseSensitive', 'MariaDB', 'Oracle')) {
        $names += "Run tests (windows-latest, $category, $category.Basic_tests.*)"
    }
    foreach ($distribution in @('All', 'SQLite', 'SQLServer', 'MariaDB', 'PostgreSQL', 'Oracle')) {
        foreach ($rid in @('win-x64', 'win-x86', 'win-arm64', 'linux-x64', 'linux-arm64', 'linux-musl-x64', 'linux-musl-arm64', 'osx-x64', 'osx-arm64')) {
            if ($distribution -eq 'All') {
                $names += "CLI $rid"
            } else {
                $names += "CLI $distribution $rid"
            }
        }
    }
    $names += 'Alpine amd64', 'Alpine arm64'
    foreach ($distribution in @('SQLite', 'SQLServer', 'MariaDB', 'PostgreSQL', 'Oracle')) {
        foreach ($architecture in @('amd64', 'arm64')) {
            $names += "Alpine $distribution $architecture"
        }
    }
    foreach ($database in @('Sqlite', 'SqlServer', 'SqlServerCaseSensitive', 'PostgreSQL', 'MariaDB', 'Oracle')) {
        $slim = switch ($database) {
            Sqlite { 'SQLite' }
            SqlServer { 'SQLServer' }
            SqlServerCaseSensitive { 'SQLServer' }
            default { $database }
        }
        $names += "CLI database All / $database", "CLI database $slim / $database"
    }
    if ($names.Count -ne 94) { throw 'Fixture must contain 94 required jobs.' }
    $needs = @{}
    foreach ($group in @('build-code', 'test', 'cli-distributions', 'packages', 'standalone', 'docker', 'validation-policy')) {
        $needs[$group] = @{ result = 'success' }
    }
    $jobs = @($names | ForEach-Object { @{ name = $_; status = 'completed'; conclusion = 'success'; run_id = 123; run_attempt = 1 } })
    foreach ($job in $jobs) {
        $stepNames = @()
        if ($job.name -ceq 'Build') { $stepNames = @('Restore dependencies', 'Build') }
        if ($job.name -ceq 'PR validation policy') { $stepNames = @('Check build-independent contracts') }
        if ($job.name -ceq 'NuGet libraries and installed tool') {
            $stepNames = @('Check standalone verification command contract', 'Verify packages across supported frameworks')
        }
        if ($job.name.StartsWith('Run tests (ubuntu-latest, ')) { $stepNames = @('Test on Linux') }
        if ($job.name.StartsWith('Run tests (windows-latest, ')) { $stepNames = @('Test on Windows') }
        if ($job.name.StartsWith('CLI ')) { $stepNames = @('Verify self-contained runtime and execution') }
        if ($job.name.StartsWith('CLI database ')) { $stepNames = @('Test published CLI and installed tool against database') }
        if ($job.name -cmatch '^CLI (?:SQLite |SQLServer |MariaDB |PostgreSQL |Oracle )?win-(?:x64|arm64)$') {
            $stepNames += @('Check per-user MSI authoring regressions', 'Build MSI from verified Windows binary',
                'Check verified Windows MSI metadata', 'Verify installed MSI, major upgrade and uninstall')
        }
        if ($job.name -cin @('CLI linux-x64', 'CLI linux-arm64')) {
            $stepNames += @('Build Debian packages from verified Linux binary', 'Verify Debian installation, package upgrade and purge')
        }
        if ($job.name.StartsWith('Alpine ')) {
            $stepNames = @('Build native image for verification')
            if ($job.name -cin @('Alpine amd64', 'Alpine arm64')) {
                $stepNames += @('Verify Alpine globalization, migration and bundled skill',
                    'Ensure SQLite client for entrypoint verification', 'Verify default image entrypoint')
            } else {
                $stepNames += 'Verify selected profile and bundled skill'
                if ($job.name.StartsWith('Alpine SQLite ')) {
                    $stepNames += 'Verify Alpine globalization, migration and bundled skill'
                }
            }
        }
        $job.steps = @($stepNames | ForEach-Object { @{ name = $_; status = 'completed'; conclusion = 'success' } })
    }
    return @{ needs = $needs; jobs = $jobs }
}

function ConvertTo-ApiJobFixture {
    param(
        [object[]]$Jobs
    )

    # Expected API names are independent of the production mapping.
    foreach ($job in $Jobs) {
        $copy = $job.Clone()
        $prefix = switch -CaseSensitive -Regex ($job.name) {
            '^Build$' {
                'Build'
                break
            }
            '^NuGet libraries and installed tool$' {
                'Packages'
                break
            }
            '^Run tests \((ubuntu|windows)-latest, Basic_tests\)$' {
                'Isolated tests'
                break
            }
            '^Run tests \(' {
                'Database tests'
                break
            }
            '^CLI database ' {
                'CLI distributions'
                break
            }
            '^CLI ' {
                'Standalone CLI'
                break
            }
            '^Alpine ' {
                'Docker'
                break
            }
        }
        if ($prefix) {
            $copy.name = "$prefix / $($job.name)"
        }
        $copy
    }
}

function Invoke-Gate($Fixture, [int] $Attempt = 1, [switch]$RawJobEvidence) {
    $jobs = $Fixture.jobs
    if (!$RawJobEvidence) {
        $jobs = @(ConvertTo-ApiJobFixture -Jobs $Fixture.jobs)
    }
    & $gate -NeedsJson (ConvertTo-Json -InputObject $Fixture.needs -Depth 10 -Compress) `
        -JobsJson (ConvertTo-Json -InputObject $jobs -Depth 10 -Compress) -RunId 123 -RunAttempt $Attempt
}

function Assert-Rejected([string] $Name, [scriptblock] $Action, [string] $Message) {
    $errorMessage = $null
    try { & $Action } catch { $errorMessage = $_.Exception.Message }
    if (!$errorMessage -or $errorMessage -notmatch $Message) {
        throw "'$Name' must fail for '$Message'; observed '$errorMessage'."
    }
    $script:passed++
}

$fixture = New-Fixture
Invoke-Gate $fixture
$script:passed++

# Reject bare historical names and success from another reusable caller.
foreach ($apiName in @((ConvertTo-ApiJobFixture -Jobs (New-Fixture).jobs).name | Where-Object { $_ -cne 'PR validation policy' })) {
    $leafName = $apiName.Substring($apiName.IndexOf(' / ') + 3)
    foreach ($wrongName in @($leafName, "Unexpected / $leafName", "Extra / $apiName")) {
        $fixture = New-Fixture
        $fixture.jobs = @(ConvertTo-ApiJobFixture -Jobs $fixture.jobs)
        ($fixture.jobs | Where-Object name -CEQ $apiName).name = $wrongName
        Assert-Rejected "wrong reusable caller $wrongName" { Invoke-Gate $fixture -RawJobEvidence } 'Missing required job'
    }
}

# Optional reports and security analysis do not replace any required producer.
$fixture = New-Fixture
$fixture.jobs += @{ name = 'Create test report'; status = 'completed'; conclusion = 'success'; run_id = 123; run_attempt = 1 }
$fixture.jobs += @{ name = 'Analyze Code Security'; status = 'completed'; conclusion = 'failure'; run_id = 123; run_attempt = 1 }
Invoke-Gate $fixture
$script:passed++
$fixture.jobs[3].conclusion = 'failure'
Assert-Rejected 'green report with red test' { Invoke-Gate $fixture } 'Required job.*Run tests.*failure'

foreach ($conclusion in @('failure', 'cancelled', 'skipped', 'timed_out', 'neutral', 'action_required', 'unknown', $null)) {
    $fixture = New-Fixture
    $fixture.jobs[0].conclusion = $conclusion
    Assert-Rejected "job conclusion '$conclusion'" { Invoke-Gate $fixture } "Required job 'Build'"
}
foreach ($status in @('queued', 'in_progress', 'waiting', $null)) {
    $fixture = New-Fixture
    $fixture.jobs[0].status = $status
    Assert-Rejected "job status '$status'" { Invoke-Gate $fixture } "Required job 'Build'"
}

# Removing any required lane must fail even if GitHub's matrix group is green.
foreach ($name in (New-Fixture).jobs.name) {
    $fixture = New-Fixture
    $fixture.jobs = @($fixture.jobs | Where-Object name -CNE $name)
    Assert-Rejected "missing $name" { Invoke-Gate $fixture } 'Missing required job'
}
$fixture = New-Fixture
$fixture.jobs = @()
Assert-Rejected 'empty job evidence' { Invoke-Gate $fixture } 'Missing required job'
$fixture = New-Fixture
$fixture.jobs += $fixture.jobs[0].Clone()
Assert-Rejected 'duplicate required job' { Invoke-Gate $fixture } 'Duplicate required job'

foreach ($group in @('build-code', 'test', 'cli-distributions', 'packages', 'standalone', 'docker', 'validation-policy')) {
    foreach ($result in @('failure', 'cancelled', 'skipped', 'unknown', $null)) {
        $fixture = New-Fixture
        $fixture.needs[$group].result = $result
        Assert-Rejected "dependency $group result '$result'" { Invoke-Gate $fixture } 'Required dependency'
    }
    $fixture = New-Fixture
    $fixture.needs.Remove($group)
    Assert-Rejected "missing dependency $group" { Invoke-Gate $fixture } 'Missing required dependency'
}

$fixture = New-Fixture
$fixture.jobs[0].run_id = 456
Assert-Rejected 'different run' { Invoke-Gate $fixture } 'run ID'
$fixture = New-Fixture
$fixture.jobs[0].Remove('run_id')
Assert-Rejected 'missing run identity' { Invoke-Gate $fixture } 'run ID'
foreach ($attempt in @(0, 2, 'unknown', $null)) {
    $fixture = New-Fixture
    $fixture.jobs[0].run_attempt = $attempt
    Assert-Rejected "invalid job attempt '$attempt'" { Invoke-Gate $fixture } 'run attempt'
}

# A failed-jobs rerun reuses successes from attempt 1, replacing only Build.
$fixture = New-Fixture
$fixture.jobs[0].conclusion = 'failure'
$rerunBuild = (New-Fixture).jobs[0]
$rerunBuild.run_attempt = 2
$fixture.jobs += $rerunBuild
Invoke-Gate $fixture -Attempt 2
$script:passed++
$fixture.jobs[-1].conclusion = 'failure'
$fixture.jobs[0].conclusion = 'success'
Assert-Rejected 'latest failure overrides older success' { Invoke-Gate $fixture -Attempt 2 } "Required job 'Build'.*attempt 2"
$fixture.jobs[-1].conclusion = 'cancelled'
Assert-Rejected 'latest cancellation overrides older success' { Invoke-Gate $fixture -Attempt 2 } "Required job 'Build'.*cancelled"
$fixture.jobs[-1].conclusion = 'skipped'
Assert-Rejected 'latest skip overrides older success' { Invoke-Gate $fixture -Attempt 2 } "Required job 'Build'.*skipped"
$fixture.jobs[-1].conclusion = 'success'
$fixture.jobs += $fixture.jobs[-1].Clone()
Assert-Rejected 'duplicate in latest attempt' { Invoke-Gate $fixture -Attempt 2 } 'Duplicate required job'

# Every correctness step matters even if its containing job is green. These
# cases distinguish checking producer execution from checking only job summaries.
foreach ($job in (New-Fixture).jobs) {
    foreach ($step in $job.steps) {
        $fixture = New-Fixture
        $target = $fixture.jobs | Where-Object name -CEQ $job.name
        $target.steps = @($target.steps | Where-Object name -CNE $step.name)
        Assert-Rejected "missing $($job.name) / $($step.name)" { Invoke-Gate $fixture } 'Missing required step'
        foreach ($conclusion in @('failure', 'skipped', 'cancelled', $null)) {
            $fixture = New-Fixture
            $target = $fixture.jobs | Where-Object name -CEQ $job.name
            ($target.steps | Where-Object name -CEQ $step.name).conclusion = $conclusion
            Assert-Rejected "green job with $conclusion step $($job.name) / $($step.name)" { Invoke-Gate $fixture } 'Required step'
        }
    }
}
$fixture = New-Fixture
$fixture.jobs[0].steps[0].status = 'in_progress'
Assert-Rejected 'incomplete mandatory step' { Invoke-Gate $fixture } 'Required step'
$fixture = New-Fixture
$fixture.jobs[0].steps += $fixture.jobs[0].steps[0].Clone()
Assert-Rejected 'duplicate mandatory step' { Invoke-Gate $fixture } 'Duplicate required step'
$fixture = New-Fixture
$fixture.jobs[0].Remove('steps')
Assert-Rejected 'missing producer-step evidence' { Invoke-Gate $fixture } 'Missing required step'
$fixture = New-Fixture
foreach ($job in $fixture.jobs) {
    # Cross-platform exclusions and diagnostic uploads are intentionally not
    # required producer steps for these jobs.
    if ($job.name.StartsWith('Run tests (ubuntu-latest, ')) {
        $job.steps += @{ name = 'Test on Windows'; status = 'completed'; conclusion = 'skipped' }
    }
    if ($job.name.StartsWith('Run tests (windows-latest, ')) {
        $job.steps += @{ name = 'Test on Linux'; status = 'completed'; conclusion = 'skipped' }
    }
    if ($job.name.StartsWith('CLI ') -and $job.name -cnotmatch '^CLI (?:SQLite |SQLServer |MariaDB |PostgreSQL |Oracle )?win-(?:x64|arm64)$') {
        $job.steps += @{ name = 'Build MSI from verified Windows binary'; status = 'completed'; conclusion = 'skipped' }
    }
    $job.steps += @{ name = 'Upload diagnostics'; status = 'completed'; conclusion = 'skipped' }
}
Invoke-Gate $fixture
$script:passed++

Assert-Rejected 'non-object dependencies' { & $gate -NeedsJson '[]' -JobsJson '[]' -RunId 123 -RunAttempt 1 } 'needs object'
Assert-Rejected 'non-array jobs' { & $gate -NeedsJson '{}' -JobsJson '{}' -RunId 123 -RunAttempt 1 } 'jobs array'
Assert-Rejected 'malformed evidence' { & $gate -NeedsJson '{}' -JobsJson 'invalid' -RunId 123 -RunAttempt 1 } 'JSON'
Write-Host "PASS: $script:passed PR validation policy cases."
