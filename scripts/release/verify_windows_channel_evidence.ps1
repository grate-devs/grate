param(
    [Parameter(Mandatory)][string]$EvidenceDirectory,
    [Parameter(Mandatory)][string]$Version,
    [Parameter(Mandatory)][string]$ReleaseRunId,
    [Parameter(Mandatory)][string]$SourceCommit,
    [string]$ValidationRunId = $env:GITHUB_RUN_ID,
    [Parameter(Mandatory)][string]$OutputPath
)
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot/windows_channel_common.ps1"
$files = @(Get-ChildItem -LiteralPath $EvidenceDirectory -Recurse -File -Filter verification.json)
$records = @($files | ForEach-Object { Get-Content -LiteralPath $_.FullName -Raw | ConvertFrom-Json })
Assert-WindowsChannelEvidence -Records $records -Version $Version -ReleaseRunId $ReleaseRunId -SourceCommit $SourceCommit -ValidationRunId $ValidationRunId
$records | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $OutputPath -Encoding utf8NoBOM
Write-Output 'PASS: every native profile/installer/architecture and all six Chocolatey packages passed for the exact original release.'
