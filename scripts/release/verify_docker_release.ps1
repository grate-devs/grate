#!/usr/bin/env pwsh
[CmdletBinding()]
param([string]$Report)
. "$PSScriptRoot/release_common.ps1"
function Confirm-DockerRelease([string[]]$Tags, $ExpectedDigest) {
    if ($null -ne $ExpectedDigest -and $ExpectedDigest -cnotmatch '\Asha256:[a-f0-9]{64}\z') { throw 'A valid build digest is required.' }
    if (!$Tags -or @($Tags | Where-Object { $_ -cnotmatch '\A(?:gratedevs|erikbra)/grate:[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}\z' }).Count) { throw 'Expected explicit canonical/compatibility Docker Hub tags.' }
    $registries = @{}
    $results = foreach ($tag in $Tags) {
        $repository, $reference = $tag.Split(':',2)
        try {
            if (!$registries.ContainsKey($repository)) { $registries[$repository] = New-Registry $repository }
            $digest = (Get-RegistryManifest $registries[$repository] $reference).Digest
            $status = if (!$ExpectedDigest) { 'observed_without_build_digest' } elseif ($digest -ceq $ExpectedDigest) { 'verified' } else { 'digest_mismatch' }
            @{ tag = $tag; digest = $digest; status = $status }
        } catch { @{ tag = $tag; status = 'unavailable_or_invalid_manifest' } }
    }
    @{ expected_digest = $(if ($ExpectedDigest) { $ExpectedDigest } else { $null }); status = $(if (@($results | Where-Object status -cne 'verified').Count) { 'failed' } else { 'verified' }); tags = @($results) }
}
if ($MyInvocation.InvocationName -ne '.') {
    $tags = @($env:DOCKER_TAGS -split '\r?\n' | Where-Object { $_ -ne '' })
    $buildDigest = if ($env:EXPECTED_DIGEST) { $env:EXPECTED_DIGEST } else { $null }
    $result = Confirm-DockerRelease $tags $buildDigest
    $result.build_push_outcome = if ($env:BUILD_OUTCOME) { $env:BUILD_OUTCOME } else { 'unknown' }
    Write-ReleaseJson $Report $result
    if ($env:GITHUB_STEP_SUMMARY) {
        $summary = "## Docker publication verification`n`nBuilt digest: ``$($result.expected_digest)```n`n"
        foreach ($entry in $result.tags) { $summary += "- ``$($entry.tag)``: $($entry.status)`n" }
        if ($result.status -cne 'verified') { $summary += "`nPublication is incomplete or inconsistent. Inspect both repositories; do not rebuild or blindly retry a partially published version.`n" }
        [IO.File]::AppendAllText($env:GITHUB_STEP_SUMMARY, $summary)
    }
    $result | ConvertTo-Json -Depth 100
    if ($result.status -cne 'verified') { exit 1 }
}
