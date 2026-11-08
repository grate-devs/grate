#!/usr/bin/env pwsh
[CmdletBinding()]
param(
    [string]$CanonicalAuthfile,
    [string]$Report
)

. "$PSScriptRoot/release_common.ps1"

function Get-CanonicalAuthorization {
    param([string]$Path)

    $auths = (Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json -AsHashtable).auths
    foreach ($hostName in @('https://index.docker.io/v1/', 'docker.io', 'registry-1.docker.io')) {
        if (!$auths[$hostName] -or !$auths[$hostName].ContainsKey('auth')) {
            continue
        }

        $encoded = $auths[$hostName].auth
        $credentialBytes = [Convert]::FromBase64String($encoded)
        $credential = [Text.Encoding]::UTF8.GetString($credentialBytes).Split(':', 2)
        if ($credential.Length -ne 2 -or $credential[0] -cne 'gratedevs' -or !$credential[1]) {
            throw 'Expected organization-owned Docker login.'
        }

        return 'Basic ' + $encoded
    }

    throw 'Docker Hub inline login is unavailable.'
}

function Get-RepositoryGrants {
    param(
        [string]$Repository,
        [string]$Authorization
    )

    $scope = [Uri]::EscapeDataString("repository:${Repository}:pull,push")
    $headers = @{ Authorization = $Authorization }
    $response = Invoke-ReleaseHttp "https://auth.docker.io/token?service=registry.docker.io&scope=$scope" $headers -NoRedirects -TimeoutSeconds 30
    $data = ConvertFrom-ResponseJson $response
    $token = if ($data.token) {
        $data.token
    } else {
        $data.access_token
    }

    $parts = $token.Split('.')
    if ($parts.Length -ne 3) {
        throw 'Unexpected token format.'
    }

    $payload = $parts[1].Replace('-', '+').Replace('_', '/')
    $payload += '=' * ((4 - $payload.Length % 4) % 4)
    $claimBytes = [Convert]::FromBase64String($payload)
    $claims = [Text.Encoding]::UTF8.GetString($claimBytes) | ConvertFrom-Json -AsHashtable
    if ($claims.aud -cne 'registry.docker.io' -or $claims.exp -le [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()) {
        throw 'Unexpected audience or expired token.'
    }

    $actions = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($grant in $claims.access) {
        if ($grant.type -ceq 'repository' -and $grant.name -ceq $Repository) {
            foreach ($action in $grant.actions) {
                $null = $actions.Add($action)
            }
        }
    }

    return ,$actions
}

function Test-DockerAccess {
    param(
        [string]$CanonicalAuth,
        [string]$LegacyAuth,
        [scriptblock]$RequestGrants = {
            param($Repository, $Authorization)
            Get-RepositoryGrants $Repository $Authorization
        }
    )

    $boundaries = @(
        @{
            Identity = 'organization_oidc'
            Repository = 'gratedevs/grate'
            Authorization = $CanonicalAuth
            RequiresPush = $true
        }
        @{
            Identity = 'organization_oidc'
            Repository = 'erikbra/grate'
            Authorization = $CanonicalAuth
            RequiresPush = $false
        }
        @{
            Identity = 'legacy_token'
            Repository = 'erikbra/grate'
            Authorization = $LegacyAuth
            RequiresPush = $true
        }
    )

    $results = foreach ($boundary in $boundaries) {
        $entry = @{
            identity = $boundary.Identity
            repository = $boundary.Repository
        }

        try {
            $actions = & $RequestGrants $boundary.Repository $boundary.Authorization
            $pull = @($actions).Contains('pull')
            $push = @($actions).Contains('push')
            $passed = if ($boundary.RequiresPush) {
                $pull -and $push
            } else {
                !$push
            }

            $entry.pull = $pull
            $entry.push = $push
            $entry.status = if ($passed) {
                'verified'
            } else {
                'unexpected_grants'
            }
        } catch {
            $status = $_.Exception.Data['StatusCode']
            $entry.status = if (!$boundary.RequiresPush -and $status -in @(401, 403)) {
                'verified_denial'
            } elseif ($status) {
                "token_endpoint_http_$status"
            } else {
                'token_request_or_response_invalid'
            }
        }

        $entry
    }

    $failed = @($results | Where-Object { $_.status -cnotin @('verified', 'verified_denial') })
    @{
        status = if ($failed.Count) {
            'failed'
        } else {
            'verified'
        }
        grants = @($results)
    }
}

if ($MyInvocation.InvocationName -ne '.') {
    try {
        $canonical = Get-CanonicalAuthorization $CanonicalAuthfile
        if ($env:DOCKER_HUB_USER -cne 'erikbra' -or !$env:DOCKER_HUB_TOKEN) {
            throw 'Legacy credential must belong to erikbra.'
        }

        $credentials = "$($env:DOCKER_HUB_USER):$($env:DOCKER_HUB_TOKEN)"
        $legacy = 'Basic ' + [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($credentials))
        $result = Test-DockerAccess $canonical $legacy
    } catch {
        $result = @{
            status = 'failed'
            grants = @()
            error = 'publishing_identity_configuration_invalid'
        }
    }

    Write-ReleaseJson $Report $result
    $result | ConvertTo-Json -Depth 100

    if ($env:GITHUB_STEP_SUMMARY) {
        $summary = "## Docker identity grant check (no image publication)`n`nResult: $($result.status)`n`n"
        foreach ($grant in $result.grants) {
            $summary += "- $($grant.identity) → ``$($grant.repository)``: $($grant.status)`n"
        }

        Add-Content -LiteralPath $env:GITHUB_STEP_SUMMARY -Value $summary -NoNewline -Encoding utf8NoBOM
    }

    if ($result.status -cne 'verified') {
        exit 1
    }
}
