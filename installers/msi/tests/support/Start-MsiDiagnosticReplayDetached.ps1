#!/usr/bin/env pwsh
param(
    [Parameter(Mandatory)][hashtable]$Parameters,
    [string]$ScriptPath = (Join-Path $PSScriptRoot '../../Test-InstallerLifecycle.ps1'),
    [ValidateRange(1, 450)][int]$DeadlineSeconds = 450
)

$ErrorActionPreference = 'Stop'
if (!$IsWindows -or $env:GITHUB_ACTIONS -ne 'true' -or $env:RUNNER_ENVIRONMENT -ne 'github-hosted') {
    throw 'Detached MSI replay requires a disposable GitHub-hosted Windows runner.'
}
$directory = [IO.Path]::GetFullPath([string]$Parameters.OutputDirectory) + '-detached'
New-Item -ItemType Directory -Path $directory | Out-Null
function Write-LaunchStage {
    param(
        [string]$Phase
    )
    $stage = @{
        Phase = $Phase
        Utc = [DateTime]::UtcNow.ToString('o')
    }
    $stage | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $directory 'launch-stage.json')
    $stage | ConvertTo-Json -Compress | Add-Content -LiteralPath (Join-Path $directory 'launch-stages.jsonl')
}
$configPath = Join-Path $directory 'entry-configuration.json'
@{
    Parameters = $Parameters
    TestScript = (Resolve-Path -LiteralPath $ScriptPath).Path
    ReplayScript = (Join-Path $PSScriptRoot 'Invoke-MsiLifecycleDiagnosticReplay.ps1')
    DeadlineSeconds = $DeadlineSeconds
} | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $configPath
$entry = Join-Path $directory 'entry.ps1'
@'
param(
    [string]$ConfigurationPath,
    [string]$EvidenceDirectory
)
$ErrorActionPreference = 'Stop'
function Write-EntryStage {
    param(
        [string]$Phase
    )
    $stage = @{
        Phase = $Phase
        Utc = [DateTime]::UtcNow.ToString('o')
    }
    $stage | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $EvidenceDirectory 'entry-stage.json')
    $stage | ConvertTo-Json -Compress | Add-Content -LiteralPath (Join-Path $EvidenceDirectory 'entry-stages.jsonl')
}
$completion = @{
    StartedUtc = [DateTime]::UtcNow.ToString('o')
    ReplayReturned = $false
    Succeeded = $false
    FailureType = $null
}
try {
    Write-EntryStage 'BeforeConfigurationRead'
    $entryConfiguration = Get-Content -LiteralPath $ConfigurationPath -Raw | ConvertFrom-Json -AsHashtable
    Write-EntryStage 'BeforeReplay'
    & $entryConfiguration.ReplayScript -Parameters $entryConfiguration.Parameters -ScriptPath $entryConfiguration.TestScript -DeadlineSeconds $entryConfiguration.DeadlineSeconds
    if (!$?) {
        throw 'Diagnostic replay returned a failure status.'
    }
    $completion.ReplayReturned = $true
    Write-EntryStage 'AfterReplay'
    $completion.Succeeded = $true
} catch {
    $completion.FailureType = $_.Exception.GetType().FullName
    Write-Host 'Detached MSI replay failed; inspect retained phase evidence.'
} finally {
    $completion.CompletedUtc = [DateTime]::UtcNow.ToString('o')
    $target = Join-Path $EvidenceDirectory 'entry-completion.json'
    $temporary = $target + '.' + [guid]::NewGuid().ToString('N') + '.tmp'
    $completion | ConvertTo-Json | Set-Content -LiteralPath $temporary
    [IO.File]::Move($temporary, $target)
}
if (!$completion.Succeeded) {
    exit 1
}
'@ | Set-Content -LiteralPath $entry
Write-LaunchStage 'BeforeNativeAddType'
if ($null -eq ('Grate.MsiTests.MsiLifecycleNativeProcess' -as [type])) {
    Add-Type -Path (Join-Path $PSScriptRoot 'MsiLifecycle.NativeProcess.cs') -ErrorAction Stop
}
Write-LaunchStage 'AfterNativeAddType'
$arguments = '-NoLogo -NoProfile -NonInteractive -File "{0}" -ConfigurationPath "{1}" -EvidenceDirectory "{2}"' -f $entry, $configPath, $directory
$process = $null
try {
    Write-LaunchStage 'BeforeDetachedStart'
    $process = [Grate.MsiTests.MsiLifecycleNativeProcess]::Start(
        (Join-Path $PSHOME 'pwsh.exe'), $arguments,
        (Join-Path $directory 'entry.stdout.log'), (Join-Path $directory 'entry.stderr.log'),
        $ExecutionContext.SessionState.Path.CurrentFileSystemLocation.Path)
    @{
        ProcessId = $process.Id
        StartedUtc = [DateTime]::UtcNow.ToString('o')
        DeadlineSeconds = $DeadlineSeconds
        Waited = $false
    } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $directory 'launch.json')
    Write-LaunchStage 'DetachedStarted'
} finally {
    if ($null -ne $process) {
        # Release only our handle; never reopen the PID or kill a process tree.
        $process.Dispose()
    }
}
Write-Host 'Started detached MSI replay. Atomic entry completion must be checked separately.'
