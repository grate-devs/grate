#!/usr/bin/env pwsh
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$root = Join-Path ([IO.Path]::GetTempPath()) ('grate-pr-validation-' + [Guid]::NewGuid().ToString('N'))
$names = @('GITHUB_API_URL', 'GITHUB_REPOSITORY', 'GITHUB_RUN_ID', 'GITHUB_RUN_ATTEMPT', 'GH_TOKEN', 'NEEDS_JSON')
$saved = @{}
foreach ($name in $names) { $saved[$name] = [Environment]::GetEnvironmentVariable($name) }
try {
    New-Item -ItemType Directory -Path $root | Out-Null
    Copy-Item "$PSScriptRoot/Invoke-PRValidation.ps1" $root
    @'
param($NeedsJson, $JobsJson, $RunId, $RunAttempt)
if ($NeedsJson -cne '{"fixture":true}' -or $RunId -ne '123' -or $RunAttempt -ne '2') { throw 'Caller changed the decision context.' }
$items = @($JobsJson | ConvertFrom-Json)
if ($items.Count -ne 101) { throw 'Caller lost a page of jobs.' }
foreach ($index in 0..99) {
    if ($items[$index].name -cne ('job-' + ($index + 1))) { throw 'Caller lost or duplicated a job across pages.' }
}
if ($items[100].name -cne 'last-page') { throw 'Caller lost the final page of jobs.' }
$fixture.DecisionCalled = $true
'@ | Set-Content "$root/Assert-PRValidation.ps1"
    $env:GITHUB_API_URL = 'https://api.example.invalid'
    $env:GITHUB_REPOSITORY = 'owner/repo'
    $env:GITHUB_RUN_ID = '123'
    $env:GITHUB_RUN_ATTEMPT = '2'
    $env:GH_TOKEN = 'fixture-token'
    $env:NEEDS_JSON = '{"fixture":true}'
    $fixture = @{
        Requests = @()
        ApiFails = $false
        DecisionCalled = $false
        Jobs = @(@(1..100 | ForEach-Object { @{ name = "job-$_" } }) + @{ name = 'last-page' })
    }
    function Invoke-RestMethod {
        param($Uri, $Headers, $TimeoutSec)
        if ($fixture.ApiFails) { throw 'Fixture API unavailable' }
        if ($Headers.Authorization -cne 'Bearer fixture-token' -or $TimeoutSec -ne 30) { throw 'Incorrect API authentication or timeout.' }
        $fixture.Requests += $Uri
        $request = [regex]::Match($Uri, '^https://api\.example\.invalid/repos/owner/repo/actions/runs/123/jobs\?filter=all&per_page=(?<size>[1-9][0-9]*)&page=(?<page>[1-9][0-9]*)$')
        if ($request.Success) {
            $size = [int]$request.Groups['size'].Value
            $offset = ([int]$request.Groups['page'].Value - 1) * $size
            return @{ jobs = @($fixture.Jobs | Select-Object -Skip $offset -First $size) }
        }
        throw "Unexpected API request: $Uri"
    }
    & "$root/Invoke-PRValidation.ps1"
    if (!$fixture.DecisionCalled -or $fixture.Requests.Count -ne 3) { throw 'Pagination did not deliver all three pages to the decision.' }

    $fixture.ApiFails = $true
    $fixture.DecisionCalled = $false
    $rejected = $false
    try { & "$root/Invoke-PRValidation.ps1" } catch { $rejected = $_.Exception.Message -eq 'Fixture API unavailable' }
    if (!$rejected -or $fixture.DecisionCalled) { throw 'API failure must stop validation.' }

    $env:NEEDS_JSON = ''
    $rejected = $false
    try { & "$root/Invoke-PRValidation.ps1" } catch { $rejected = $_.Exception.Message -match 'NEEDS_JSON is missing' }
    if (!$rejected) { throw 'Missing dependency context must stop validation.' }
    Write-Host 'PR validation API caller: pagination, context, API failure and missing context passed.'
} finally {
    foreach ($name in $names) { [Environment]::SetEnvironmentVariable($name, $saved[$name]) }
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
}
