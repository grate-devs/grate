#!/usr/bin/env pwsh
param(
    [Parameter(Mandatory)]
    [ValidateSet('net8.0', 'net9.0', 'net10.0', 'net11.0')]
    [string]$Framework,
    [Parameter(Mandatory)]
    [ValidateSet('baseline-first', 'scoped-first')]
    [string]$Order,
    [Parameter(Mandatory)]
    [string]$ResultsDirectory
)

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true
$repository = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$results = [IO.Path]::GetFullPath($ResultsDirectory)
New-Item -ItemType Directory -Path $results -Force | Out-Null
$image = 'gvenzl/oracle-free@sha256:33322969a450d72c507b08d7f690d9e1d9b60aebaebc35a75b7c0b8ab4baac77'
Push-Location $repository
try {
    # Pull before timing either suite; each gets its own fixture/container.
    docker pull $image
    docker pull testcontainers/ryuk:0.14.0
    $assembly = Join-Path $repository "unittests/Oracle/bin/Debug/$Framework/Oracle.dll"
    $identity = [ordered]@{
        SourceRevision = (git rev-parse HEAD).Trim()
        Framework = $Framework
        Configuration = 'Debug'
        ExpectedCasesPerVariant = 321
        PreservedUnpooledCase = 'Oracle.Running_MigrationScripts.DropDatabase.Ensure_database_gets_dropped'
        AssemblySha256 = (Get-FileHash -LiteralPath $assembly -Algorithm SHA256).Hash
        OracleImage = $image
        ImageDetails = @(docker image inspect $image --format '{{json .RepoDigests}} {{.Id}} {{.Architecture}}')
        Order = $Order
        RunId = [string]$env:GITHUB_RUN_ID
        RunAttempt = [string]$env:GITHUB_RUN_ATTEMPT
        RuntimeInfo = @(dotnet --info)
        HostCpuCount = [Environment]::ProcessorCount
        DockerInfo = @(docker info --format '{{.OSType}} {{.Architecture}} CPUs={{.NCPU}} Memory={{.MemTotal}}')
    }
    $identity | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath "$results/identity.json"
    $variants = if ($Order -eq 'baseline-first') { @('baseline', 'scoped') } else { @('scoped', 'baseline') }
    $runs = @()
    foreach ($variant in $variants) {
        $variantDirectory = Join-Path $results $variant
        New-Item -ItemType Directory -Path $variantDirectory -Force | Out-Null
        $info = [Diagnostics.ProcessStartInfo]::new('dotnet')
        $info.UseShellExecute = $false
        $info.RedirectStandardOutput = $true
        $info.RedirectStandardError = $true
        $info.Environment['GRATE_ORACLE_SCOPED_POOLING'] = if ($variant -eq 'scoped') { 'true' } else { 'false' }
        $info.Environment['GrateTestConfig__DockerImage'] = $image
        $info.Environment.Remove('GrateTestConfig__AdminConnectionString') | Out-Null
        $info.Environment['LogLevel'] = 'Warning'
        $info.Environment['TZ'] = 'UTC'
        foreach ($argument in @(
            $assembly, '--stop-on-fail', 'on', '--long-running', '60', '--timeout', '20m',
            '--minimum-expected-tests', '321', '--results-directory', $variantDirectory,
            '--report-xunit-trx', '--coverage', '--coverage-output-format', 'xml'
        )) {
            $info.ArgumentList.Add($argument)
        }
        $process = [Diagnostics.Process]::new()
        $process.StartInfo = $info
        $watch = [Diagnostics.Stopwatch]::StartNew()
        $startedAt = [DateTimeOffset]::UtcNow
        $samples = @()
        $stdout = $null
        $stderr = $null
        $timedOut = $false
        Write-Host "Starting complete $Framework $variant suite."
        try {
            if (!$process.Start()) {
                throw 'Could not start the Oracle test process.'
            }
            $startedAt = [DateTimeOffset]$process.StartTime.ToUniversalTime()
            $stdout = $process.StandardOutput.ReadToEndAsync()
            $stderr = $process.StandardError.ReadToEndAsync()
            while (!$process.HasExited) {
                if ($watch.Elapsed.TotalMinutes -gt 21) {
                    $timedOut = $true
                    $process.Kill($true)
                    break
                }
                $containers = @(docker stats --no-stream --format '{{json .}}' |
                    ForEach-Object { $_ | ConvertFrom-Json })
                $samples += [pscustomobject]@{
                    At = [DateTimeOffset]::UtcNow
                    ElapsedSeconds = $watch.Elapsed.TotalSeconds
                    Containers = $containers
                    MemAvailable = @(Get-Content -LiteralPath /proc/meminfo | Where-Object { $_ -match '^MemAvailable:' })
                }
                $samples | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath "$variantDirectory/resources.json"
                Write-Host "$Framework $variant elapsed $([int]$watch.Elapsed.TotalSeconds)s; sampled $($containers.Count) containers."
                Start-Sleep -Seconds 10
            }
            $process.WaitForExit()
            $exitCode = $process.ExitCode
            $completedAt = [DateTimeOffset]$process.ExitTime.ToUniversalTime()
        } finally {
            if (!$process.HasExited) {
                $process.Kill($true)
                $process.WaitForExit()
            }
            if ($stdout) {
                $stdout.GetAwaiter().GetResult() | Set-Content -LiteralPath "$variantDirectory/stdout.log"
            }
            if ($stderr) {
                $stderr.GetAwaiter().GetResult() | Set-Content -LiteralPath "$variantDirectory/stderr.log"
            }
            $process.Dispose()
        }
        $runs += [pscustomobject]@{
            Variant = $variant
            StartedAt = $startedAt
            CompletedAt = $completedAt
            ElapsedSeconds = ($completedAt - $startedAt).TotalSeconds
            ExitCode = $exitCode
            TimedOut = $timedOut
        }
        $runs | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath "$results/runs.json"
        Write-Host "Finished $Framework $variant with exit code $exitCode."
    }
    & "$PSScriptRoot/Compare-OraclePoolingExperiment.ps1" -ResultsDirectory $results
    if (@($runs | Where-Object { $_.ExitCode -ne 0 -or $_.TimedOut }).Count -gt 0) {
        throw 'At least one complete Oracle suite failed or timed out.'
    }
} finally {
    Pop-Location
}
