#!/usr/bin/env pwsh
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string] $Executable,
    [Parameter(Mandatory)][string] $BuildManifest,
    [Parameter(Mandatory)][string] $OutputDirectory,
    [Parameter(Mandatory)][ValidateSet('native', 'container-native')][string] $ExecutionMode,
    [ValidateRange(2, 1000)][int] $Iterations = 10,
    [ValidateRange(0, 100)][int] $WarmupIterations = 1,
    [ValidateRange(1, 10000)][int] $SmallScriptCount = 100,
    [ValidateRange(1, 1000000)][int] $LargeRowCount = 10000,
    [ValidateRange(1, 3600)][int] $TimeoutSeconds = 120,
    [string] $EnvironmentNotes = ''
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Benchmark.Common.ps1')

if (!$IsLinux) {
    throw 'This harness currently supports native Linux only; no other platform result is implied.'
}
foreach ($command in @('sqlite3', 'tar')) {
    if (!(Get-Command $command -CommandType Application -ErrorAction SilentlyContinue)) {
        throw "Required command is missing: $command"
    }
}
if (!(Test-Path -LiteralPath '/usr/bin/time')) {
    throw 'GNU time must be installed at /usr/bin/time.'
}
$timeVersion = & /usr/bin/time --version 2>&1
if ($LASTEXITCODE -ne 0 -or ($timeVersion -join ' ') -notmatch 'GNU') {
    throw 'This harness requires GNU time for per-process maximum resident memory.'
}

$Executable = (Resolve-Path -LiteralPath $Executable).Path
$BuildManifest = (Resolve-Path -LiteralPath $BuildManifest).Path
$manifest = Get-Content -LiteralPath $BuildManifest -Raw | ConvertFrom-Json
foreach ($property in @('schemaVersion', 'sourceCommit', 'sourceDirty', 'sdkVersion', 'targetFramework', 'runtimeVersion', 'profile', 'runtimeIdentifier', 'configuration', 'publishProperties', 'publishCommand', 'executableSha256')) {
    if ($manifest.PSObject.Properties.Name -notcontains $property) {
        throw "Build manifest is missing '$property'."
    }
}
if ($manifest.schemaVersion -ne 1) {
    throw "Unsupported build manifest schema: $($manifest.schemaVersion)"
}
$architecture = [Runtime.InteropServices.RuntimeInformation]::ProcessArchitecture.ToString().ToLowerInvariant()
if ($architecture -notin @('x64', 'arm64') -or $manifest.runtimeIdentifier -cne "linux-$architecture") {
    throw "Executable RID '$($manifest.runtimeIdentifier)' does not match Linux $architecture. Emulated/cross-RID measurements are not accepted."
}
$executableHash = (Get-FileHash -LiteralPath $Executable -Algorithm SHA256).Hash.ToLowerInvariant()
if ($executableHash -cne $manifest.executableSha256.ToLowerInvariant()) {
    throw 'Executable SHA256 does not match its build manifest.'
}
$OutputDirectory = [IO.Path]::GetFullPath($OutputDirectory)
$publishDirectory = Split-Path -Parent $Executable
if ($OutputDirectory.StartsWith($publishDirectory + '/', [StringComparison]::Ordinal) -or $OutputDirectory -ceq $publishDirectory) {
    throw 'Results must be stored outside the published artifact directory.'
}
if (Test-Path -LiteralPath $OutputDirectory) {
    throw "Results directory already exists; use a new directory: $OutputDirectory"
}
New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
Copy-Item -LiteralPath $BuildManifest -Destination (Join-Path $OutputDirectory 'build-manifest.json')
New-Item -ItemType Directory -Path (Join-Path $OutputDirectory 'processes') | Out-Null
$rawPath = Join-Path $OutputDirectory 'measurements.jsonl'
$measurements = [Collections.Generic.List[object]]::new()
$processNumber = 0

function Invoke-BenchmarkProcess {
    param(
        [Parameter(Mandatory)][string[]] $Arguments,
        [Parameter(Mandatory)][string] $Workload,
        [Parameter(Mandatory)][string] $Phase,
        [Parameter(Mandatory)][string] $ExtractionCondition,
        [Parameter(Mandatory)][string] $ExtractionDirectory,
        [int] $Iteration = 0,
        [int] $ExpectedExitCode = 0
    )

    $script:processNumber++
    $prefix = Join-Path $OutputDirectory ('processes/{0:D5}-{1}-{2}-{3}' -f $script:processNumber, $Workload, $ExtractionCondition, $Phase)
    $statisticsPath = "$prefix.time.txt"
    $start = [Diagnostics.ProcessStartInfo]::new('/usr/bin/time')
    foreach ($argument in @('-f', '%e|%U|%S|%M', '-o', $statisticsPath, '--', $Executable) + $Arguments) {
        $start.ArgumentList.Add($argument)
    }
    $start.UseShellExecute = $false
    $start.RedirectStandardInput = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $start.WorkingDirectory = $OutputDirectory
    $start.Environment['DOTNET_BUNDLE_EXTRACT_BASE_DIR'] = $ExtractionDirectory
    $start.Environment['LC_ALL'] = 'C.UTF-8'
    $start.Environment['LANG'] = 'C.UTF-8'
    $start.Environment['TZ'] = 'UTC'
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $start
    $watch = [Diagnostics.Stopwatch]::StartNew()
    try {
        if (!$process.Start()) {
            throw 'Could not start benchmark process.'
        }
        $process.StandardInput.Close()
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        if (!$process.WaitForExit($TimeoutSeconds * 1000)) {
            $process.Kill($true)
            $process.WaitForExit()
            $stdout.GetAwaiter().GetResult() | Set-Content -LiteralPath "$prefix.stdout.txt" -Encoding utf8NoBOM
            $stderr.GetAwaiter().GetResult() | Set-Content -LiteralPath "$prefix.stderr.txt" -Encoding utf8NoBOM
            throw "Benchmark process timed out after $TimeoutSeconds seconds."
        }
        $watch.Stop()
        $stdout.GetAwaiter().GetResult() | Set-Content -LiteralPath "$prefix.stdout.txt" -Encoding utf8NoBOM
        $stderr.GetAwaiter().GetResult() | Set-Content -LiteralPath "$prefix.stderr.txt" -Encoding utf8NoBOM
        # GNU time prefixes failure statistics with a diagnostic line; retain the
        # complete raw file and parse the final numeric record only.
        $statistics = @(Get-Content -LiteralPath $statisticsPath)[-1].Split('|')
        if ($statistics.Count -ne 4) {
            throw "Unrecognized GNU time output: $statisticsPath"
        }
        $culture = [Globalization.CultureInfo]::InvariantCulture
        $measurement = [pscustomobject] @{
            workload = $Workload
            phase = $Phase
            iteration = $Iteration
            extractionCondition = $ExtractionCondition
            osCacheCondition = 'uncontrolled; no cold-cache claim'
            elapsedMilliseconds = $watch.Elapsed.TotalMilliseconds
            gnuTimeElapsedSeconds = [double]::Parse($statistics[0], $culture)
            userCpuSeconds = [double]::Parse($statistics[1], $culture)
            systemCpuSeconds = [double]::Parse($statistics[2], $culture)
            maximumResidentKiB = [long]::Parse($statistics[3], $culture)
            exitCode = $process.ExitCode
            extractionBytesAfter = Get-DirectoryBytes $ExtractionDirectory
            arguments = $Arguments
            stdout = [IO.Path]::GetRelativePath($OutputDirectory, "$prefix.stdout.txt")
            stderr = [IO.Path]::GetRelativePath($OutputDirectory, "$prefix.stderr.txt")
            time = [IO.Path]::GetRelativePath($OutputDirectory, $statisticsPath)
        }
        $measurement | ConvertTo-Json -Depth 6 -Compress | Add-Content -LiteralPath $rawPath -Encoding utf8NoBOM
        $script:measurements.Add($measurement)
        if ($process.ExitCode -ne $ExpectedExitCode) {
            throw "Unexpected CLI exit code $($process.ExitCode) for $Workload; inspect $prefix.stdout.txt and $prefix.stderr.txt."
        }
        if ($Workload -in @('help', 'version-parse-error')) {
            $providers = @()
            if ($manifest.profile -ceq 'all-in-one') {
                $providers = @('sqlserver', 'postgresql', 'mariadb', 'oracle', 'sqlite')
            }
            $text = $stdout.GetAwaiter().GetResult() + $stderr.GetAwaiter().GetResult()
            Assert-BenchmarkStartup -Workload $Workload -Output $text -Providers $providers
        }
    }
    finally {
        $process.Dispose()
    }
}

function Get-MigrationArguments {
    param(
        [Parameter(Mandatory)][string] $Database,
        [Parameter(Mandatory)][string] $Scripts,
        [Parameter(Mandatory)][string] $Output
    )

    $quotedDatabase = $Database.Replace('"', '""')
    return @(
        '--databasetype=sqlite'
        "--connectionstring=Data Source=`"$quotedDatabase`";Pooling=False"
        "--sqlfilesdirectory=$Scripts"
        "--outputPath=$Output"
        '--version=benchmark-1'
        '--silent'
        '--log-format=console'
    )
}

$hostMetadata = [ordered] @{
    schemaVersion = 1
    startedAtUtc = [DateTime]::UtcNow.ToString('o')
    executionMode = $ExecutionMode
    environmentNotes = $EnvironmentNotes
    migrationLogFormat = 'console (explicit, identical inside and outside CI)'
    executionModeBasis = 'Operator attestation; matching process architecture is checked, hypervisor/emulator detection is not reliable.'
    architecture = $architecture
    operatingSystem = [Runtime.InteropServices.RuntimeInformation]::OSDescription
    kernel = (& uname -a) -join ' '
    cpu = Get-Content -LiteralPath '/proc/cpuinfo' -Raw
    memory = Get-Content -LiteralPath '/proc/meminfo' -Raw
    cpuMax = $(if (Test-Path -LiteralPath '/sys/fs/cgroup/cpu.max') { Get-Content -LiteralPath '/sys/fs/cgroup/cpu.max' -Raw } else { $null })
    memoryMax = $(if (Test-Path -LiteralPath '/sys/fs/cgroup/memory.max') { Get-Content -LiteralPath '/sys/fs/cgroup/memory.max' -Raw } else { $null })
    powerShellVersion = $PSVersionTable.PSVersion.ToString()
    sqliteAssertionVersion = (& sqlite3 --version) -join ' '
    timeVersion = $timeVersion -join "`n"
    sourceManifest = $manifest
    iterations = $Iterations
    warmupIterations = $WarmupIterations
    smallScriptCount = $SmallScriptCount
    largeRowCount = $LargeRowCount
    timing = 'New process wall time includes GNU time wrapper startup. Setup, data copies, assertions and footprint scans are outside timing.'
    osCaches = 'Uncontrolled throughout. First extraction means an unused bundle extraction directory, not cold OS page caches.'
    externalWork = 'SQLite file I/O and SQL execution included in migration timings; no remote connection/authentication/network work. Startup uses help and a version-argument parse error. These measurements do not isolate all in-process application work from SQLite work.'
    versionCoverage = 'The current CLI --version sets the migration version and requires a value. version-parse-error measures its existing exit-1 argument-error path; it is not informational version startup.'
    transactionCoverage = 'SQLite provider does not support grate DDL transactions. Failure assertions cover nontransactional stop/error/history behavior; transaction rollback is untested.'
    executableBytes = (Get-Item -LiteralPath $Executable).Length
    installedFileBytes = Get-DirectoryBytes $publishDirectory
    complete = $false
}
$metadataPath = Join-Path $OutputDirectory 'metadata.json'
$hostMetadata | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $metadataPath -Encoding utf8NoBOM

# Record a reproducible compressed download surrogate for the complete publish
# directory, rather than equating the single executable with its sidecar files.
$archivePath = Join-Path $OutputDirectory 'publish.tar.gz'
& tar --sort=name --mtime=@0 --owner=0 --group=0 --numeric-owner -czf $archivePath -C $publishDirectory .
if ($LASTEXITCODE -ne 0) {
    throw "Could not archive published artifact; tar exited $LASTEXITCODE."
}
$hostMetadata['compressedArchiveBytes'] = (Get-Item -LiteralPath $archivePath).Length
$fixtures = New-BenchmarkFixtures -Root (Join-Path $OutputDirectory 'fixtures') -SmallScriptCount $SmallScriptCount -LargeRowCount $LargeRowCount
$fixtures | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $OutputDirectory 'fixtures.json') -Encoding utf8NoBOM
$warmExtraction = Join-Path $OutputDirectory 'extraction/reused'
Invoke-BenchmarkProcess -Arguments @('--help') -Workload 'help' -Phase 'setup' -ExtractionCondition 'reused' -ExtractionDirectory $warmExtraction

$seedDatabase = Join-Path $OutputDirectory 'up-to-date-seed.db'
$seedArguments = Get-MigrationArguments -Database $seedDatabase -Scripts $fixtures.SmallRoot -Output (Join-Path $OutputDirectory 'seed-output')
Invoke-BenchmarkProcess -Arguments $seedArguments -Workload 'prepare-up-to-date' -Phase 'setup' -ExtractionCondition 'reused' -ExtractionDirectory $warmExtraction
Assert-BenchmarkDatabase -Database $seedDatabase -Fixture 'small' -Fixtures $fixtures
$seedHistory = Get-BenchmarkHistory $seedDatabase
# This value was written by the packaged CLI's SQL, independently of the sqlite3
# client used to inspect the resulting file.
$hostMetadata['bundledSqliteVersion'] = Invoke-SqliteQuery $seedDatabase 'SELECT version FROM benchmark_engine;'

foreach ($condition in @('first-extraction', 'reused')) {
    foreach ($workload in @('help', 'version-parse-error', 'up-to-date', 'many-small', 'large', 'failure')) {
        Write-Host "Measuring $workload ($condition): $Iterations samples and $WarmupIterations warmups."
        for ($iteration = 1; $iteration -le $WarmupIterations + $Iterations; $iteration++) {
            $phase = 'measurement'
            if ($iteration -le $WarmupIterations) {
                $phase = 'warmup'
            }
            $runRoot = Join-Path $OutputDirectory "work/$condition/$workload/$iteration"
            New-Item -ItemType Directory -Path $runRoot -Force | Out-Null
            $extraction = $warmExtraction
            if ($condition -eq 'first-extraction') {
                $extraction = Join-Path $runRoot 'extraction'
            }
            $cliArguments = @("--$workload")
            $expectedExitCode = 0
            if ($workload -eq 'version-parse-error') {
                $cliArguments = @('--version')
                $expectedExitCode = 1
            }
            $fixture = $null
            $database = Join-Path $runRoot 'benchmark.db'
            if ($workload -eq 'up-to-date') {
                Copy-Item -LiteralPath $seedDatabase -Destination $database
                $fixture = 'small'
            }
            elseif ($workload -eq 'many-small') {
                $fixture = 'small'
            }
            elseif ($workload -in @('large', 'failure')) {
                $fixture = $workload
                if ($workload -eq 'failure') {
                    $expectedExitCode = 1
                }
            }
            if ($null -ne $fixture) {
                $scripts = $fixtures.SmallRoot
                if ($fixture -eq 'large') {
                    $scripts = $fixtures.LargeRoot
                }
                elseif ($fixture -eq 'failure') {
                    $scripts = $fixtures.FailureRoot
                }
                $cliArguments = Get-MigrationArguments -Database $database -Scripts $scripts -Output (Join-Path $runRoot 'output')
            }
            Invoke-BenchmarkProcess -Arguments $cliArguments -Workload $workload -Phase $phase -Iteration $iteration -ExtractionCondition $condition -ExtractionDirectory $extraction -ExpectedExitCode $expectedExitCode
            if ($null -ne $fixture) {
                Assert-BenchmarkDatabase -Database $database -Fixture $fixture -Fixtures $fixtures
                if ($workload -eq 'up-to-date') {
                    Assert-BenchmarkEqual (Get-BenchmarkHistory $database) $seedHistory 'Rerun preserves exact migration identities'
                }
            }
            # Keep raw evidence, SQL fixtures and the seed, but avoid retaining a
            # database/output copy for every repetition in uploaded CI artifacts.
            if (Test-Path -LiteralPath $database) {
                Remove-Item -LiteralPath $database
            }
            if (Test-Path -LiteralPath (Join-Path $runRoot 'output')) {
                Remove-Item -LiteralPath (Join-Path $runRoot 'output') -Recurse -Force
            }
            if ($condition -eq 'first-extraction') {
                if (Test-Path -LiteralPath $extraction) {
                    Remove-Item -LiteralPath $extraction -Recurse -Force
                }
            }
        }
    }
}

$summary = @(
    foreach ($group in $measurements | Where-Object phase -EQ 'measurement' | Group-Object workload, extractionCondition) {
        [pscustomobject] @{
            workload = $group.Group[0].workload
            extractionCondition = $group.Group[0].extractionCondition
            elapsedMilliseconds = Get-BenchmarkDistribution @($group.Group.elapsedMilliseconds)
            maximumResidentKiB = Get-BenchmarkDistribution @($group.Group.maximumResidentKiB)
            extractionBytesAfter = Get-BenchmarkDistribution @($group.Group.extractionBytesAfter)
        }
    }
)
$summary | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $OutputDirectory 'summary.json') -Encoding utf8NoBOM
$hostMetadata['finishedAtUtc'] = [DateTime]::UtcNow.ToString('o')
$hostMetadata['complete'] = $true
$hostMetadata | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $metadataPath -Encoding utf8NoBOM
Write-Host "PASS: measured and independently checked CLI benchmark; results: $OutputDirectory"
