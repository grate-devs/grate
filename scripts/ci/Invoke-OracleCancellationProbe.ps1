#!/usr/bin/env pwsh
$ErrorActionPreference = 'Stop'
$forwarded = @($args)
$directory = $env:GRATE_ORACLE_CLI_PROBE_DIRECTORY
New-Item -ItemType Directory -Path $directory -Force | Out-Null
$prefix = Join-Path $directory ([Guid]::NewGuid().ToString('N'))
$start = [Diagnostics.ProcessStartInfo]::new($env:GRATE_ORACLE_CLI_PROBE_TARGET)
$start.UseShellExecute = $false
$start.RedirectStandardOutput = $true
$start.RedirectStandardError = $true
foreach ($argument in $forwarded) {
    $start.ArgumentList.Add($argument)
}
$watch = [Diagnostics.Stopwatch]::StartNew()
$process = [Diagnostics.Process]::Start($start)
try {
    $stdoutTask = $process.StandardOutput.ReadToEndAsync()
    $stderrTask = $process.StandardError.ReadToEndAsync()
    $forced = !$process.WaitForExit(45000)
    if ($forced) {
        $process.Kill($true)
        if (!$process.WaitForExit(5000)) {
            throw 'Owned Oracle CLI process did not exit after termination.'
        }
    }
    $drains = [Threading.Tasks.Task]::WhenAll([Threading.Tasks.Task[]]@($stdoutTask, $stderrTask))
    if (!$drains.Wait(5000)) {
        throw 'Oracle CLI output did not finish after process exit.'
    }
    $stdout = $stdoutTask.GetAwaiter().GetResult()
    $stderr = $stderrTask.GetAwaiter().GetResult()
    $stdoutBytes = [Text.Encoding]::UTF8.GetByteCount($stdout)
    $stderrBytes = [Text.Encoding]::UTF8.GetByteCount($stderr)
    foreach ($argument in $forwarded) {
        if ($argument -match '(?i)^--(?:admin)?connectionstring=(.*)$') {
            $connection = [Data.Common.DbConnectionStringBuilder]::new()
            $connection.set_ConnectionString($Matches[1])
            foreach ($key in @('Password', 'Pwd')) {
                if ($connection.ContainsKey($key) -and [string]$connection[$key]) {
                    $stdout = $stdout.Replace([string]$connection[$key], '[redacted]')
                    $stderr = $stderr.Replace([string]$connection[$key], '[redacted]')
                }
            }
        }
    }
    Set-Content -LiteralPath "$prefix.stdout.log" -Value $stdout -Encoding utf8NoBOM
    Set-Content -LiteralPath "$prefix.stderr.log" -Value $stderr -Encoding utf8NoBOM
    $exitCode = if ($forced) { 124 } else { $process.ExitCode }
    [pscustomobject]@{
        ElapsedSeconds = $watch.Elapsed.TotalSeconds
        ActualExitCode = $process.ExitCode
        ExitCode = $exitCode
        ForcedKill = $forced
        StdoutBytes = $stdoutBytes
        StderrBytes = $stderrBytes
        CommandTimeoutOne = @($forwarded | Where-Object { $_ -match '(?i)^--commandtimeout=1$' }).Count -gt 0
        AdminCommandTimeoutOne = @($forwarded | Where-Object { $_ -match '(?i)^--admincommandtimeout=1$' }).Count -gt 0
    } | ConvertTo-Json | Set-Content -LiteralPath "$prefix.json" -Encoding utf8NoBOM
    [Console]::Out.WriteLine("Oracle CLI probe: exit=$exitCode forced=$forced stdoutBytes=$stdoutBytes stderrBytes=$stderrBytes")
    exit $exitCode
} finally {
    $process.Dispose()
}
