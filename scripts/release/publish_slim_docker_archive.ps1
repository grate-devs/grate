#!/usr/bin/env pwsh
[CmdletBinding()]
param(
    [ValidateSet('SQLite', 'SQLServer', 'MariaDB', 'PostgreSQL', 'Oracle')]
    [string]$Distribution,
    [string]$Version,
    [string]$SourceCommit,
    [string]$ExpectedDigest,
    [string]$Archive,
    [string]$Report,
    [string]$VerificationReport,
    [string]$Authfile,
    [Alias('Mode')]
    [ValidateSet('Verify', 'Preflight', 'Publish')]
    [string]$Operation = 'Verify',
    [switch]$Prerelease
)

$runAsCommand = $MyInvocation.InvocationName -ne '.'
# Imported command scripts have their own param blocks. Keep this invocation's
# bound values independent of their script-scope parameters.
$requestedParameters = @{} + $PSBoundParameters
. "$PSScriptRoot/publish_docker_archive.ps1"
. "$PSScriptRoot/../../installers/docker/release_tags.ps1"

function Get-SlimDockerTags {
    param(
        [ValidateSet('SQLite', 'SQLServer', 'MariaDB', 'PostgreSQL', 'Oracle')]
        [string]$Distribution,
        [string]$Version,
        [bool]$Prerelease = $false
    )

    $versionTag = Get-NormalizedDockerVersion $Version
    $alias = $Distribution.ToLowerInvariant()
    $immutableTag = "$alias-$versionTag"
    if ($immutableTag.Length -gt 128) {
        throw 'Profile-prefixed version exceeds the Docker tag length limit.'
    }
    $immutableTag
    if (!$Prerelease -and !$versionTag.Contains('-')) {
        $alias
    }
}

function Assert-SlimDockerVerification {
    param(
        [string]$Path,
        [hashtable]$Expected
    )

    $verification = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json -AsHashtable
    if ($verification.status -cne 'verified' -or $verification.mode -cnotin @('Verify', 'Preflight')) {
        throw 'A successful retained Docker build verification is required.'
    }
    foreach ($name in @('distribution', 'version', 'source_commit', 'expected_digest')) {
        if ($verification[$name] -cne $Expected[$name]) {
            throw "Retained Docker verification does not match $name."
        }
    }
}

function Invoke-SlimDockerArchive {
    param(
        [ValidateSet('SQLite', 'SQLServer', 'MariaDB', 'PostgreSQL', 'Oracle')]
        [string]$Distribution,
        [string]$Version,
        [string]$SourceCommit,
        [string]$ExpectedDigest,
        [string]$Archive,
        [string]$Report,
        [string]$VerificationReport,
        [string]$Authfile,
        [Alias('Mode')]
        [ValidateSet('Verify', 'Preflight', 'Publish')]
        [string]$Operation = 'Verify',
        [bool]$Prerelease = $false
    )

    $result = @{
        distribution = $Distribution
        version = $Version
        source_commit = $SourceCommit
        expected_digest = $ExpectedDigest
        destination = 'gratedevs/grate'
        mode = $Operation
        status = 'in_progress'
        tags = @{}
        started_at = Get-Timestamp
    }
    Write-ReleaseJson $Report $result
    try {
        if ($SourceCommit -cnotmatch '\A[a-f0-9]{40}\z') {
            throw 'A source commit SHA is required.'
        }
        $tags = @(Get-SlimDockerTags -Distribution $Distribution -Version $Version -Prerelease $Prerelease)
        $result.version = Get-NormalizedDockerVersion $Version
        if ($env:DOCKER_HUB_USER -or $env:DOCKER_HUB_TOKEN) {
            throw 'Slim canonical publication cannot use compatibility credentials.'
        }
        if ($Operation -eq 'Publish') {
            Assert-SlimDockerVerification -Path $VerificationReport -Expected $result
            if (!$Authfile -or ![IO.File]::Exists($Authfile)) {
                throw 'Canonical Docker authentication file is missing.'
            }
        }
        $result.digest = Test-DockerArchive $ExpectedDigest $Archive
        if ($Operation -ne 'Verify') {
            $registry = New-Registry 'gratedevs/grate'
            foreach ($tag in $tags) {
                $existing = Get-ExistingDigest $registry $tag
                if ($tag -ceq $tags[0] -and $null -ne $existing -and $existing -cne $ExpectedDigest) {
                    throw 'Slim immutable version already has a conflicting digest.'
                }
                $result.tags[$tag] = @{
                    status = 'preflight_verified'
                    already_present = $existing -ceq $ExpectedDigest
                }
            }
            Write-ReleaseJson $Report $result
        }
        if ($Operation -eq 'Publish') {
            foreach ($tag in $tags) {
                $entry = $result.tags[$tag]
                if (!$entry.already_present) {
                    $entry.status = 'copy_started'
                    Write-ReleaseJson $Report $result
                    $copyArguments = @(
                        'copy', '--all', '--preserve-digests', '--retry-times', '2',
                        '--dest-authfile', $Authfile, "oci-archive:$Archive",
                        "docker://docker.io/gratedevs/grate:$tag"
                    )
                    $null = Invoke-Skopeo $copyArguments 'slim canonical copy'
                }
                Test-CanonicalSource $Authfile (':' + $tag) $ExpectedDigest
                $entry.status = 'verified'
                $entry.digest = $ExpectedDigest
                Write-ReleaseJson $Report $result
            }
            foreach ($tag in $tags) {
                Test-CanonicalSource $Authfile (':' + $tag) $ExpectedDigest
            }
        }
        $result.status = 'verified'
        $result.completed_at = Get-Timestamp
        Write-ReleaseJson $Report $result
        $result
    } catch {
        $result.status = 'failed'
        $result.completed_at = Get-Timestamp
        Write-ReleaseJson $Report $result
        throw
    }
}

if ($runAsCommand) {
    try {
        $null = Invoke-SlimDockerArchive @requestedParameters
    } catch {
        throw 'Slim Docker archive verification/publication failed; inspect the redacted report.'
    }
}
