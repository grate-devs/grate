[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot/windows_channel_common.ps1"

function Assert-RejectedContext {
    param(
        $Run,
        $Release,
        [string]$Commit,
        [string]$ExpectedVersion
    )
    $rejected = $false
    try {
        Assert-WindowsChannelReleaseContext -Run $Run -Release $Release -TagCommit $Commit -Version $ExpectedVersion
    } catch {
        $rejected = $true
    }
    if (!$rejected) {
        throw 'A mismatched release context was accepted.'
    }
}
$commit = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
$run = [pscustomobject]@{
    event = 'release'
    status = 'completed'
    conclusion = 'success'
    head_repository = @{ full_name = 'grate-devs/grate' }
    repository = @{ full_name = 'grate-devs/grate' }
    head_branch = '2.3.0'
    head_sha = $commit
    path = '.github/workflows/build.yml'
}
$release = [pscustomobject]@{ tag_name = '2.3.0'; draft = $false; prerelease = $false; published_at = '2026-11-10T20:17:36Z' }
Assert-WindowsChannelReleaseContext -Run $run -Release $release -TagCommit $commit -Version '2.3.0'
foreach ($field in @('event', 'status', 'conclusion', 'head_sha', 'head_branch', 'path')) {
    $changed = $run | ConvertTo-Json | ConvertFrom-Json
    $changed.$field = 'wrong'
    Assert-RejectedContext -Run $changed -Release $release -Commit $commit -ExpectedVersion '2.3.0'
}
foreach ($field in @('draft', 'prerelease')) {
    $changed = $release | ConvertTo-Json | ConvertFrom-Json
    $changed.$field = $true
    Assert-RejectedContext -Run $run -Release $changed -Commit $commit -ExpectedVersion '2.3.0'
}
$fork = $run | ConvertTo-Json | ConvertFrom-Json
$fork.head_repository.full_name = 'outsider/grate'
Assert-RejectedContext -Run $fork -Release $release -Commit $commit -ExpectedVersion '2.3.0'
Assert-RejectedContext -Run $run -Release $release -Commit $commit -ExpectedVersion '2.3.0-rc.1'
Write-Output 'PASS: original stable release accepted; wrong trigger/status/conclusion/SHA/tag/workflow/fork and draft/prerelease rejected.'
