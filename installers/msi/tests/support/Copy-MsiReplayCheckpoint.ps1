#!/usr/bin/env pwsh
param(
    [Parameter(Mandatory)][string]$LifecycleDirectory,
    [Parameter(Mandatory)][string]$OutputDirectory
)

$ErrorActionPreference = 'Stop'
New-Item -ItemType Directory -Path $OutputDirectory | Out-Null
$allowed = @(
    'Phase', 'Event', 'Utc', 'StartedUtc', 'CompletedUtc', 'ElapsedSeconds', 'ElapsedBeforeCleanupSeconds',
    'DeadlineSeconds', 'TimeoutSeconds', 'State', 'ProcessId', 'ChildProcessId', 'ChildExited', 'ChildExitCode',
    'ExitCode', 'TimedOut', 'LastChildStage', 'LifecycleCompleted', 'Succeeded', 'ReplayReturned',
    'FailureType', 'StdoutComplete', 'StderrComplete', 'Waited', 'Observation'
)
function Select-PhaseFields {
    param(
        [Collections.IDictionary]$Record
    )
    $filtered = [ordered]@{}
    foreach ($key in $Record.Keys) {
        if ($allowed -notcontains [string]$key) {
            continue
        }
        $value = $Record[$key]
        if ($value -is [Collections.IDictionary]) {
            $filtered[$key] = Select-PhaseFields $value
        } elseif ($null -eq $value -or $value -is [string] -or $value -is [ValueType]) {
            $filtered[$key] = $value
        }
    }
    return $filtered
}
$items = [Collections.Generic.List[object]]::new()
function Copy-PhaseFile {
    param(
        [string]$Source,
        [string]$Destination
    )
    $record = [ordered]@{
        Name = $Destination
        ObservedUtc = [DateTime]::UtcNow.ToString('o')
        State = 'Missing'
        InvalidRecords = 0
    }
    try {
        if (!(Test-Path -LiteralPath $Source -PathType Leaf)) {
            $items.Add($record)
            return
        }
        $file = Get-Item -LiteralPath $Source
        $record.LastWriteUtc = $file.LastWriteTimeUtc.ToString('o')
        $stream = [IO.FileStream]::new($Source, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete)
        try {
            $reader = [IO.StreamReader]::new($stream)
            try {
                $text = $reader.ReadToEnd()
            } finally {
                $reader.Dispose()
            }
        } finally {
            $stream.Dispose()
        }
        $records = if ($Source.EndsWith('.jsonl')) { @($text -split '\r?\n' | Where-Object { $_.Trim() }) } else { @($text) }
        $safeLines = [Collections.Generic.List[string]]::new()
        foreach ($line in $records) {
            try {
                $parsed = $line | ConvertFrom-Json -AsHashtable -ErrorAction Stop
                if ($parsed -isnot [Collections.IDictionary]) {
                    throw 'Phase record is not an object.'
                }
                $safe = Select-PhaseFields $parsed
                if (!$safe.Count) {
                    throw 'Record contained no phase/status fields.'
                }
                $safeLines.Add(($safe | ConvertTo-Json -Depth 8 -Compress))
            } catch {
                $record.InvalidRecords++
            }
        }
        if (!$safeLines.Count) {
            throw 'No complete phase records were readable.'
        }
        $target = Join-Path $OutputDirectory $Destination
        [IO.Directory]::CreateDirectory((Split-Path $target)) | Out-Null
        $safeLines | Set-Content -LiteralPath $target -Encoding utf8NoBOM
        $record.State = if ($record.InvalidRecords) { 'CopiedPartial' } else { 'Copied' }
    } catch {
        $record.State = 'CopyFailed'
        $record.FailureType = $_.Exception.GetType().FullName
    }
    $items.Add($record)
}
foreach ($name in @('worker-phase.json', 'worker-phases.jsonl')) {
    Copy-PhaseFile (Join-Path $LifecycleDirectory $name) (Join-Path 'worker' $name)
}
foreach ($name in @('process.json', 'phases.jsonl')) {
    Copy-PhaseFile (Join-Path ($LifecycleDirectory + '-supervisor') $name) (Join-Path 'supervisor' $name)
}
foreach ($name in @('controller.json', 'timeline.jsonl', 'child-stage.json', 'child-stages.jsonl', 'result.json')) {
    Copy-PhaseFile (Join-Path ($LifecycleDirectory + '-replay') $name) (Join-Path 'replay' $name)
}
foreach ($name in @('launch.json', 'launch-stage.json', 'launch-stages.jsonl', 'entry-stage.json', 'entry-stages.jsonl', 'entry-completion.json')) {
    Copy-PhaseFile (Join-Path ($LifecycleDirectory + '-detached') $name) (Join-Path 'detached' $name)
}
$commands = @()
$enumerationFailed = $false
try {
    if (Test-Path -LiteralPath $LifecycleDirectory -PathType Container) {
        $commands = @(Get-ChildItem -LiteralPath $LifecycleDirectory -Filter '*.command.json' -File)
    }
} catch {
    $enumerationFailed = $true
    $items.Add(@{
        Name = 'commands/*.command.json'
        ObservedUtc = [DateTime]::UtcNow.ToString('o')
        State = 'CopyFailed'
        FailureType = $_.Exception.GetType().FullName
    })
}
if (!$commands.Count -and !$enumerationFailed) {
    $items.Add(@{
        Name = 'commands/*.command.json'
        ObservedUtc = [DateTime]::UtcNow.ToString('o')
        State = 'Missing'
    })
}
foreach ($command in $commands) {
    Copy-PhaseFile $command.FullName (Join-Path 'commands' $command.Name)
}
@{
    CapturedUtc = [DateTime]::UtcNow.ToString('o')
    DiagnosticOnly = $true
    SynchronousIoIsNotAHardWallClockGuarantee = $true
    Files = $items.ToArray()
} | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $OutputDirectory 'manifest.json')
Write-Host "Captured phase checkpoint: $($items.Count) expected/observed files. Missing and copy failures are explicit in manifest.json."
