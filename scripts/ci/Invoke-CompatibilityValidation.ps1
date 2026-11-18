#!/usr/bin/env pwsh
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

foreach ($name in @('GITHUB_API_URL', 'GITHUB_REPOSITORY', 'GITHUB_RUN_ID', 'GITHUB_RUN_ATTEMPT', 'GITHUB_SHA',
        'GITHUB_EVENT_NAME', 'GITHUB_REF', 'GH_TOKEN', 'NEEDS_JSON', 'COMPATIBILITY_TIER')) {
    if ([string]::IsNullOrWhiteSpace([Environment]::GetEnvironmentVariable($name))) {
        throw "Required environment variable $name is missing."
    }
}

$headers = @{
    Authorization = "Bearer $env:GH_TOKEN"
    Accept = 'application/vnd.github+json'
    'X-GitHub-Api-Version' = '2022-11-28'
}
$jobs = @()
$page = 1
$pageSize = 100
do {
    # Fetch every attempt so a failed-job rerun can use this run's earlier successes.
    $uri = "$env:GITHUB_API_URL/repos/$env:GITHUB_REPOSITORY/actions/runs/$env:GITHUB_RUN_ID/jobs?filter=all&per_page=$pageSize&page=$page"
    $response = Invoke-RestMethod -Uri $uri -Headers $headers -TimeoutSec 30
    if ($response.jobs -isnot [array]) {
        throw 'Expected an array from the GitHub Actions jobs API.'
    }
    $jobs += $response.jobs
    $page++
} while ($response.jobs.Count -eq $pageSize)
if ($jobs.Count -ne $response.total_count) {
    throw 'Incomplete job evidence from the GitHub Actions jobs API.'
}

& "$PSScriptRoot/Assert-CompatibilityValidation.ps1" -Needs (ConvertFrom-Json -InputObject $env:NEEDS_JSON -AsHashtable) `
    -Jobs $jobs -RunId $env:GITHUB_RUN_ID -RunAttempt $env:GITHUB_RUN_ATTEMPT -HeadSha $env:GITHUB_SHA `
    -Tier $env:COMPATIBILITY_TIER -EventName $env:GITHUB_EVENT_NAME -Ref $env:GITHUB_REF
