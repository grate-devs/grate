#!/usr/bin/env pwsh
# Only the read-only GitHub Actions token is needed, including on fork PRs.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

foreach ($name in @('GITHUB_API_URL', 'GITHUB_REPOSITORY', 'GITHUB_RUN_ID', 'GITHUB_RUN_ATTEMPT', 'GH_TOKEN', 'NEEDS_JSON')) {
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
do {
    # Include earlier attempts so GitHub's 're-run failed jobs' can reuse successful
    # producers from this same run. The policy selects the newest result per job.
    $uri = "$env:GITHUB_API_URL/repos/$env:GITHUB_REPOSITORY/actions/runs/$env:GITHUB_RUN_ID/jobs?filter=all&per_page=100&page=$page"
    $response = Invoke-RestMethod -Uri $uri -Headers $headers -TimeoutSec 30
    $jobs += @($response.jobs)
    $page++
} while (@($response.jobs).Count -eq 100)

& "$PSScriptRoot/Assert-PRValidation.ps1" -NeedsJson $env:NEEDS_JSON `
    -JobsJson (ConvertTo-Json -InputObject $jobs -Depth 20 -Compress) `
    -RunId $env:GITHUB_RUN_ID -RunAttempt $env:GITHUB_RUN_ATTEMPT
