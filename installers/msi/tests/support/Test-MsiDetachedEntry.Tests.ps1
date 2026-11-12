#!/usr/bin/env pwsh
param(
    [string]$NativeAssemblyPath,
    [string]$OutputDirectory = (Join-Path ([IO.Path]::GetTempPath()) ('msi-entry-controls-' + [guid]::NewGuid().ToString('N')))
)

$ErrorActionPreference = 'Stop'
New-Item -ItemType Directory -Path $OutputDirectory | Out-Null
$tokens = $null
$errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile(
    (Join-Path $PSScriptRoot 'Start-MsiDiagnosticReplayDetached.ps1'), [ref]$tokens, [ref]$errors)
if ($errors.Count) {
    throw ($errors | Out-String)
}
$entrySource = $ast.FindAll({
    param($node)
    $node -is [Management.Automation.Language.StringConstantExpressionAst] -and $node.Value.Contains('entry-completion.json')
}, $true)[0].Value
$entry = Join-Path $OutputDirectory 'exact generated entry.ps1'
$entrySource | Set-Content -LiteralPath $entry
$stub = Join-Path $OutputDirectory 'replay stub.ps1'
@'
param(
    [hashtable]$Parameters,
    [string]$ScriptPath,
    [int]$DeadlineSeconds
)
$ErrorActionPreference = 'Stop'
$configuration = Get-Variable -Name entryConfiguration -ValueOnly -ErrorAction Stop
if ($configuration -isnot [hashtable] -or $Parameters -isnot [hashtable] -or
    $Parameters.Nested -isnot [hashtable] -or $Parameters.Nested.Value -cne 'space; equals=value' -or
    $ScriptPath -cne $Parameters.ExpectedScript -or $DeadlineSeconds -ne 450) {
    throw 'Entry configuration did not roundtrip.'
}
@{
    ConfigurationHashtable = $true
    ParametersHashtable = $true
} | ConvertTo-Json |
    Set-Content -LiteralPath (Join-Path $Parameters.OutputDirectory 'stub-called.json')
if ($Parameters.Mode -eq 'Failure') {
    throw 'Synthetic replay failure; must not publish success.'
}
'@ | Set-Content -LiteralPath $stub
$launcher = Join-Path $OutputDirectory 'bootstrap launcher.ps1'
@'
param(
    [string]$Entry,
    [string]$ConfigPath,
    [string]$Evidence,
    [string]$NativePath
)
$ErrorActionPreference = 'Stop'
Add-Type -Path $NativePath -ErrorAction Stop
if ($null -eq ('Grate.MsiTests.MsiLifecycleNativeProcess' -as [type])) {
    throw 'Genuine native helper was not loaded.'
}
& $Entry -ConfigurationPath $ConfigPath -EvidenceDirectory $Evidence
if (!$?) {
    exit 1
}
'@ | Set-Content -LiteralPath $launcher
$nativePath = if ($NativeAssemblyPath) { (Resolve-Path -LiteralPath $NativeAssemblyPath).Path } else { Join-Path $PSScriptRoot 'MsiLifecycle.NativeProcess.cs' }
$results = @()
foreach ($mode in @('Success', 'Failure')) {
    $evidence = Join-Path $OutputDirectory "$mode evidence"
    New-Item -ItemType Directory -Path $evidence | Out-Null
    $configPath = Join-Path $evidence 'configuration with spaces.json'
    $fixture = Join-Path $evidence 'lifecycle fixture.ps1'
    '# Bootstrap-only fixture; no MSI work.' | Set-Content -LiteralPath $fixture
    @{
        Parameters = @{
            OutputDirectory = $evidence
            Mode = $mode
            ExpectedScript = $fixture
            Nested = @{ Value = 'space; equals=value' }
        }
        TestScript = $fixture
        ReplayScript = $stub
        DeadlineSeconds = 450
    } | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $configPath
    $start = [Diagnostics.ProcessStartInfo]::new((Get-Process -Id $PID).Path)
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    foreach ($argument in @('-NoLogo', '-NoProfile', '-NonInteractive', '-File', $launcher,
            '-Entry', $entry, '-ConfigPath', $configPath, '-Evidence', $evidence, '-NativePath', $nativePath)) {
        $start.ArgumentList.Add($argument)
    }
    $process = [Diagnostics.Process]::Start($start)
    try {
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        if (!$process.WaitForExit(10000)) {
            $process.Kill()
            if (!$process.WaitForExit(5000)) {
                throw 'Entry bootstrap did not terminate within five seconds.'
            }
            throw 'Entry bootstrap exceeded its bound.'
        }
        [void][Threading.Tasks.Task]::WhenAll([Threading.Tasks.Task[]]@($stdout, $stderr)).WaitAsync(
            [TimeSpan]::FromSeconds(3)).GetAwaiter().GetResult()
        $stdout.GetAwaiter().GetResult() | Set-Content -LiteralPath (Join-Path $evidence 'stdout.log')
        $stderr.GetAwaiter().GetResult() | Set-Content -LiteralPath (Join-Path $evidence 'stderr.log')
        $completion = Get-Content -LiteralPath (Join-Path $evidence 'entry-completion.json') -Raw | ConvertFrom-Json
        $expected = ($mode -eq 'Success')
        if ($completion.Succeeded -ne $expected -or $completion.ReplayReturned -ne $expected -or
            !$completion.CompletedUtc -or @(Get-ChildItem -LiteralPath $evidence -Filter '*.tmp' -File).Count -or
            !(Test-Path -LiteralPath (Join-Path $evidence 'stub-called.json')) -or
            $process.ExitCode -ne $(if ($expected) { 0 } else { 1 })) {
            throw 'Entry did not atomically publish the correct full-return/failure result.'
        }
        $stages = @(Get-Content -LiteralPath (Join-Path $evidence 'entry-stages.jsonl') | ForEach-Object { ($_ | ConvertFrom-Json).Phase })
        $expectedStages = if ($expected) { @('BeforeConfigurationRead', 'BeforeReplay', 'AfterReplay') } else { @('BeforeConfigurationRead', 'BeforeReplay') }
        if (($stages -join '|') -cne ($expectedStages -join '|')) {
            throw 'Entry stages did not match the actual replay outcome.'
        }
        $results += @{
            Mode = $mode
            ExitCode = $process.ExitCode
            BootstrapOnly = $true
            Succeeded = $completion.Succeeded
        }
    } finally {
        $process.Dispose()
    }
}
$fixtureDirectory = Join-Path $OutputDirectory 'checkpoint fixture'
New-Item -ItemType Directory -Path $fixtureDirectory | Out-Null
@{
    Phase = 'BeforeCom.ProductState'
    Utc = [DateTime]::UtcNow.ToString('o')
    Arguments = 'SECRET_ARGUMENT'
    Environment = 'SECRET_ENVIRONMENT'
} |
    ConvertTo-Json | Set-Content -LiteralPath (Join-Path $fixtureDirectory 'worker-phase.json')
@{
    phase = 'BeforeWait'
    state = 'Running'
    arguments = @('SECRET_COMMAND')
    executable = 'SECRET_EXECUTABLE'
} |
    ConvertTo-Json | Set-Content -LiteralPath (Join-Path $fixtureDirectory 'install.command.json')
@(
    (@{ Phase = 'BeforeWait'; Arguments = 'SECRET_JSONL' } | ConvertTo-Json -Compress),
    '{incomplete'
) | Set-Content -LiteralPath (Join-Path $fixtureDirectory 'worker-phases.jsonl')
New-Item -ItemType Directory -Path ($fixtureDirectory + '-replay') | Out-Null
'{invalid' | Set-Content -LiteralPath (Join-Path ($fixtureDirectory + '-replay') 'controller.json')
$checkpoint = Join-Path $OutputDirectory 'checkpoint output'
$activeWriter = [IO.FileStream]::new((Join-Path $fixtureDirectory 'worker-phase.json'), [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::ReadWrite)
try {
    & (Join-Path $PSScriptRoot 'Copy-MsiReplayCheckpoint.ps1') -LifecycleDirectory $fixtureDirectory -OutputDirectory $checkpoint
} finally {
    $activeWriter.Dispose()
}
$copied = @(Get-ChildItem -LiteralPath $checkpoint -File -Recurse | ForEach-Object { Get-Content -LiteralPath $_.FullName -Raw }) -join "`n"
if ($copied.Contains('SECRET_')) {
    throw 'Checkpoint copied arguments, environment or other non-phase material.'
}
$manifest = Get-Content -LiteralPath (Join-Path $checkpoint 'manifest.json') -Raw | ConvertFrom-Json
if (!@($manifest.Files | Where-Object State -EQ 'Missing').Count -or
    !@($manifest.Files | Where-Object State -EQ 'CopyFailed').Count -or
    !@($manifest.Files | Where-Object State -EQ 'CopiedPartial').Count -or
    !(Test-Path -LiteralPath (Join-Path $checkpoint 'commands/install.command.json'))) {
    throw 'Checkpoint did not retain readable records with explicit missing/partial states.'
}
$results | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $OutputDirectory 'result.json')
Write-Host 'PASS bootstrap-only exact generated entry: Hashtable/path roundtrip, atomic success after full return, failure remains red. No native Windows API or MSI invoked.'
