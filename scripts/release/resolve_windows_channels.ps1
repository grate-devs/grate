param([string]$Version, [string]$ReleaseRunId)
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot/windows_channel_common.ps1"
if ($env:GITHUB_EVENT_NAME -eq 'workflow_dispatch' -and $env:CHANNEL_PUBLISH -eq 'true' -and
    ($env:GITHUB_REF -cne 'refs/heads/main' -or $env:GITHUB_REPOSITORY -cne 'grate-devs/grate')) {
    throw 'Publication is restricted to the canonical repository main workflow; other refs may only validate.'
}
$headers = @{ Accept = 'application/vnd.github+json' }
if ($env:GH_TOKEN) {
    $headers.Authorization = "Bearer $env:GH_TOKEN"
}
$api = 'https://api.github.com/repos/grate-devs/grate'
if ($env:GITHUB_EVENT_NAME -eq 'workflow_run') {
    $event = Get-Content -LiteralPath $env:GITHUB_EVENT_PATH -Raw | ConvertFrom-Json
    $ReleaseRunId = [string]$event.workflow_run.id
    $Version = [string]$event.workflow_run.head_branch
} elseif ($env:GITHUB_EVENT_NAME -eq 'pull_request') {
    $release = Invoke-RestMethod "$api/releases/latest" -Headers $headers
    $Version = $release.tag_name
    $runs = Invoke-RestMethod "$api/actions/workflows/build.yml/runs?event=release&status=success&per_page=100" -Headers $headers
    $matching = @($runs.workflow_runs | Where-Object head_branch -CEQ $Version | Sort-Object created_at)
    if (!$matching.Count) {
        throw 'No successful original release run exists for the latest published stable version.'
    }
    $ReleaseRunId = [string]$matching[0].id
}
$context = Get-WindowsChannelReleaseContext -Version $Version -ReleaseRunId $ReleaseRunId
"version=$Version" | Add-Content -LiteralPath $env:GITHUB_OUTPUT
"release-run-id=$ReleaseRunId" | Add-Content -LiteralPath $env:GITHUB_OUTPUT
"source-commit=$($context.SourceCommit)" | Add-Content -LiteralPath $env:GITHUB_OUTPUT
[pscustomobject]@{
    Version = $Version
    ReleaseRunId = $ReleaseRunId
    SourceCommit = $context.SourceCommit
    Publication = 'Only the two secret-isolated jobs may submit after every native validation passes.'
} | ConvertTo-Json
