#!/usr/bin/env pwsh
. "$PSScriptRoot/release_common.ps1"
function Read-GitHubRelease([string]$Tag, [string]$Repository) {
    try {
        $result = Invoke-ReleaseProcess 'gh' @('release','view',$Tag,'--repo',$Repository,'--json','isDraft,isPrerelease') 45
        if ($result.ExitCode -ne 0) { throw 'Release lookup failed.' }
        $result.Text | ConvertFrom-Json -AsHashtable
    } catch { throw 'The requested GitHub release could not be read.' }
}
function ConvertTo-ReleaseBoolean([string]$Value, [string]$Name, $Default = $null) {
    if ($Value -ceq 'true') { return $true }
    if ($Value -ceq 'false') { return $false }
    if ($Value -ceq '' -and $null -ne $Default) { return $Default }
    throw "$Name must be true or false."
}
function Resolve-ReleaseContext([Collections.IDictionary]$Environment, [scriptblock]$ReleaseReader = { param($Tag,$Repository) Read-GitHubRelease $Tag $Repository }) {
    $event = $Environment['EVENT_NAME']
    $releaseTag = ''
    $publish = $false
    $declaredPrerelease = $null
    if ($event -ceq 'release') {
        if ($Environment['RELEASE_ACTION'] -cne 'published' -or (ConvertTo-ReleaseBoolean $Environment['RELEASE_DRAFT'] 'RELEASE_DRAFT')) { throw 'Only a published non-draft release event can enable publishing.' }
        $releaseTag = $Environment['RELEASE_TAG']
        if (!$releaseTag) { throw 'A published release event requires RELEASE_TAG.' }
        $publish = $true
        $declaredPrerelease = ConvertTo-ReleaseBoolean $Environment['RELEASE_PRERELEASE'] 'RELEASE_PRERELEASE'
    } elseif ($event -ceq 'workflow_dispatch') {
        $publish = ConvertTo-ReleaseBoolean $Environment['MANUAL_PUBLISH'] 'MANUAL_PUBLISH' $false
        $releaseTag = [string]$Environment['MANUAL_TAG']
        if ($publish -and !$releaseTag) { throw 'MANUAL_TAG is required when publishing is enabled.' }
    }
    $version = if ($releaseTag) { $releaseTag } else { $Environment['GITVERSION_SEMVER'] }
    if ($version -cnotmatch "\A$script:SemVerPattern\z") { throw 'Version must be SemVer without a v prefix, build metadata, or numeric leading zeroes.' }
    $prerelease = $version.Contains('-')
    $checkoutRef = $Environment['GITHUB_SHA']
    if ($checkoutRef -cnotmatch '\A(?:[0-9a-fA-F]{40}|[0-9a-fA-F]{64})\z') { throw 'GITHUB_SHA must identify the commit being built.' }
    if ($releaseTag -and $Environment['GITHUB_REF'] -cne "refs/tags/$releaseTag") { throw 'Release tag must match the workflow ref; dispatch with --ref TAG.' }
    if ($publish -and $event -ceq 'workflow_dispatch') {
        $repository = $Environment['GITHUB_REPOSITORY']
        if ($repository -cnotmatch '\A[A-Za-z0-9][A-Za-z0-9-]*/[A-Za-z0-9_.-]+\z') { throw 'GITHUB_REPOSITORY is required for release validation.' }
        try { $metadata = & $ReleaseReader $releaseTag $repository } catch { throw 'The requested GitHub release could not be read.' }
        if ($metadata -isnot [Collections.IDictionary] -or $metadata['isDraft'] -isnot [bool] -or $metadata['isPrerelease'] -isnot [bool]) { throw 'GitHub release metadata must include boolean draft and prerelease settings.' }
        if ($metadata['isDraft']) { throw 'Publishing requires an existing published GitHub release; drafts are not allowed.' }
        $declaredPrerelease = $metadata['isPrerelease']
    }
    if ($publish -and $declaredPrerelease -ne $prerelease) { throw 'Tag prerelease suffix and GitHub release prerelease setting disagree.' }
    [ordered]@{ checkout_ref = $checkoutRef; core_version = $version.Split('-')[0]; version = $version; publish = $publish.ToString().ToLowerInvariant(); prerelease = $prerelease.ToString().ToLowerInvariant(); release_tag = $releaseTag }
}
function Invoke-ReleaseContext {
    if (!$env:GITHUB_OUTPUT) { throw 'GITHUB_OUTPUT is required.' }
    $environment = @{}
    foreach ($entry in [Environment]::GetEnvironmentVariables().GetEnumerator()) { $environment[$entry.Key] = $entry.Value }
    $context = Resolve-ReleaseContext $environment
    $content = ($context.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)`n" }) -join ''
    [IO.File]::AppendAllText($env:GITHUB_OUTPUT, $content, [Text.UTF8Encoding]::new($false))
    if ($env:GITHUB_STEP_SUMMARY) {
        $summary = "## Release context`n`n"
        foreach ($entry in @(@('Version','version'),@('Checkout ref','checkout_ref'),@('Publish','publish'),@('Prerelease','prerelease'))) { $summary += '- ' + $entry[0] + ': `' + $context[$entry[1]] + "`` `n".Replace('` ', '`') }
        [IO.File]::AppendAllText($env:GITHUB_STEP_SUMMARY, $summary, [Text.UTF8Encoding]::new($false))
    }
}
if ($MyInvocation.InvocationName -ne '.') { Invoke-ReleaseContext }
