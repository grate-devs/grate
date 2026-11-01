#!/usr/bin/env pwsh
# Keep a blocked MSI inventory/COM call inside a disposable child process, so
# the supervising CI step can retain evidence and finish with a bounded error.
param(
    [Parameter(Mandatory)][hashtable]$Parameters,
    [ValidateRange(1,360)][int]$TimeoutSeconds=300,
    [string]$ScriptPath=(Join-Path $PSScriptRoot 'Test-WinGetMsiLifecycle.ps1')
)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
if (!$IsWindows -or $env:GITHUB_ACTIONS -ne 'true' -or $env:RUNNER_ENVIRONMENT -ne 'github-hosted') { throw 'MSI lifecycle supervision requires a disposable GitHub-hosted Windows runner.' }
$directory=[IO.Path]::GetFullPath([string]$Parameters.OutputDirectory)+'-supervisor'
if (Test-Path $directory) { throw 'Supervisor evidence directory must be new.' }
New-Item -ItemType Directory -Path $directory | Out-Null
$settings=Join-Path $directory 'parameters.json'
$Parameters | ConvertTo-Json -Depth 8 | Set-Content $settings
$worker=Join-Path $directory 'worker.ps1'
@'
param([string]$Settings,[string]$Script)
$ErrorActionPreference='Stop'
$parameters=Get-Content -LiteralPath $Settings -Raw | ConvertFrom-Json -AsHashtable
& $Script @parameters
'@ | Set-Content $worker
$start=[Diagnostics.ProcessStartInfo]::new((Join-Path $PSHOME 'pwsh.exe'))
$start.UseShellExecute=$false
$start.RedirectStandardOutput=$true
$start.RedirectStandardError=$true
foreach ($argument in @('-NoLogo','-NoProfile','-NonInteractive','-MTA','-File',$worker,'-Settings',$settings,'-Script',(Resolve-Path $ScriptPath).Path)) { $start.ArgumentList.Add($argument) }
$process=[Diagnostics.Process]::new()
$process.StartInfo=$start
$result=[ordered]@{ Script=(Resolve-Path $ScriptPath).Path; TimeoutSeconds=$TimeoutSeconds; StartedUtc=[DateTime]::UtcNow.ToString('o'); TimedOut=$false; ExitCode=$null }
try {
    [void]$process.Start()
    $result.ProcessId=$process.Id
    $result | ConvertTo-Json | Set-Content "$directory/process.json"
    $stdout=$process.StandardOutput.ReadToEndAsync()
    $stderr=$process.StandardError.ReadToEndAsync()
    if (!$process.WaitForExit($TimeoutSeconds*1000)) {
        $result.TimedOut=$true
        $process.Kill($true)
        if (!$process.WaitForExit(10000)) { throw 'MSI worker could not be terminated within ten seconds.' }
    }
    $result.ExitCode=$process.ExitCode
    # Do not wait indefinitely for inherited handles held by a surviving service.
    foreach ($stream in @(@{Task=$stdout;Name='stdout'},@{Task=$stderr;Name='stderr'})) {
        try { $value=$stream.Task.WaitAsync([TimeSpan]::FromSeconds(5)).GetAwaiter().GetResult() }
        catch { $value='[Stream drain exceeded its bound or failed: '+$_.Exception.Message+']' }
        $value | Set-Content "$directory/$($stream.Name).log"
        if ($value) { Write-Host $value }
    }
    if ($result.TimedOut) { throw "MSI lifecycle worker exceeded $TimeoutSeconds seconds; partial installer and inventory evidence is retained." }
    if ($result.ExitCode -ne 0) { throw "MSI lifecycle worker failed with exit code $($result.ExitCode); inspect native and supervisor evidence." }
} finally {
    $result.CompletedUtc=[DateTime]::UtcNow.ToString('o')
    $result | ConvertTo-Json | Set-Content "$directory/process.json"
    $process.Dispose()
}
