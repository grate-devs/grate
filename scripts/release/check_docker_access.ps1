#!/usr/bin/env pwsh
[CmdletBinding()]
param([string]$CanonicalAuthfile, [string]$Report)
. "$PSScriptRoot/release_common.ps1"
function Get-CanonicalAuthorization([string]$Path) {
    $auths = (Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json -AsHashtable).auths
    foreach ($hostName in @('https://index.docker.io/v1/','docker.io','registry-1.docker.io')) {
        if ($auths[$hostName] -and $auths[$hostName].ContainsKey('auth')) {
            $encoded = $auths[$hostName].auth
            $credential = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($encoded)).Split(':',2)
            if ($credential.Length -ne 2 -or $credential[0] -cne 'gratedevs' -or !$credential[1]) { throw 'Expected organization-owned Docker login.' }
            return 'Basic ' + $encoded
        }
    }
    throw 'Docker Hub inline login is unavailable.'
}
function Get-RepositoryGrants([string]$Repository, [string]$Authorization) {
    $scope = [Uri]::EscapeDataString("repository:${Repository}:pull,push")
    $data = ConvertFrom-ResponseJson (Invoke-ReleaseHttp "https://auth.docker.io/token?service=registry.docker.io&scope=$scope" @{ Authorization = $Authorization } -NoRedirects -TimeoutSeconds 30)
    $token = if ($data.token) { $data.token } else { $data.access_token }
    $parts = $token.Split('.')
    if ($parts.Length -ne 3) { throw 'Unexpected token format.' }
    $payload = $parts[1].Replace('-','+').Replace('_','/')
    $payload += '=' * ((4 - $payload.Length % 4) % 4)
    $claims = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($payload)) | ConvertFrom-Json -AsHashtable
    if ($claims.aud -cne 'registry.docker.io' -or $claims.exp -le [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()) { throw 'Unexpected audience or expired token.' }
    $actions = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($grant in $claims.access) { if ($grant.type -ceq 'repository' -and $grant.name -ceq $Repository) { foreach ($action in $grant.actions) { $null = $actions.Add($action) } } }
    return ,$actions
}
function Test-DockerAccess([string]$CanonicalAuth, [string]$LegacyAuth, [scriptblock]$RequestGrants = { param($Repository,$Authorization) Get-RepositoryGrants $Repository $Authorization }) {
    $results = foreach ($boundary in @(@('organization_oidc','gratedevs/grate',$CanonicalAuth,$true),@('organization_oidc','erikbra/grate',$CanonicalAuth,$false),@('legacy_token','erikbra/grate',$LegacyAuth,$true))) {
        $entry = @{ identity = $boundary[0]; repository = $boundary[1] }
        try {
            $actions = & $RequestGrants $boundary[1] $boundary[2]
            $pull = @($actions).Contains('pull'); $push = @($actions).Contains('push')
            $passed = if ($boundary[3]) { $pull -and $push } else { !$push }
            $entry.pull = $pull; $entry.push = $push; $entry.status = if ($passed) { 'verified' } else { 'unexpected_grants' }
        } catch {
            $status = $_.Exception.Data['StatusCode']
            $entry.status = if (!$boundary[3] -and $status -in @(401,403)) { 'verified_denial' } elseif ($status) { "token_endpoint_http_$status" } else { 'token_request_or_response_invalid' }
        }
        $entry
    }
    @{ status = $(if (@($results | Where-Object { $_.status -cnotin @('verified','verified_denial') }).Count) { 'failed' } else { 'verified' }); grants = @($results) }
}
if ($MyInvocation.InvocationName -ne '.') {
    try {
        $canonical = Get-CanonicalAuthorization $CanonicalAuthfile
        if ($env:DOCKER_HUB_USER -cne 'erikbra' -or !$env:DOCKER_HUB_TOKEN) { throw 'Legacy credential must belong to erikbra.' }
        $legacy = 'Basic ' + [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes("$($env:DOCKER_HUB_USER):$($env:DOCKER_HUB_TOKEN)"))
        $result = Test-DockerAccess $canonical $legacy
    } catch { $result = @{ status = 'failed'; grants = @(); error = 'publishing_identity_configuration_invalid' } }
    Write-ReleaseJson $Report $result
    $result | ConvertTo-Json -Depth 100
    if ($env:GITHUB_STEP_SUMMARY) {
        $summary = "## Docker identity grant check (no image publication)`n`nResult: $($result.status)`n`n"
        foreach ($grant in $result.grants) { $summary += "- $($grant.identity) → ``$($grant.repository)``: $($grant.status)`n" }
        [IO.File]::AppendAllText($env:GITHUB_STEP_SUMMARY, $summary)
    }
    if ($result.status -cne 'verified') { exit 1 }
}
