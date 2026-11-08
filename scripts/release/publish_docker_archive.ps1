#!/usr/bin/env pwsh
[CmdletBinding()]
param([string]$Archive, [string]$Authfile, [string]$Report, [switch]$VerifyOnly, [switch]$PreflightOnly)
. "$PSScriptRoot/docker_copy_common.ps1"
function Test-DockerArchive([string]$ExpectedDigest, [string]$ArchivePath) {
    if ($ExpectedDigest -cnotmatch '\Asha256:[a-f0-9]{64}\z') { throw 'EXPECTED_DIGEST must be a SHA256 image digest.' }
    if (![IO.File]::Exists($ArchivePath)) { throw 'Docker build archive is missing.' }
    $raw = Invoke-Skopeo @('inspect','--raw',"oci-archive:$ArchivePath") 'archive inspection'
    if ((Get-ByteDigest $raw) -cne $ExpectedDigest) { throw 'Docker build archive differs from the build digest.' }
    $ExpectedDigest
}
function Confirm-DockerArchive([string]$ExpectedDigest, [string]$ArchivePath, [string]$ReportPath) {
    $result = @{ artifact = 'docker_oci_archive'; status = 'in_progress'; started_at = Get-Timestamp }
    Write-ReleaseJson $ReportPath $result
    try {
        $result.digest = Test-DockerArchive $ExpectedDigest $ArchivePath
        $result.status = 'verified'; $result.completed_at = Get-Timestamp
        Write-ReleaseJson $ReportPath $result
        $result
    } catch {
        $result.status = 'failed'; $result.completed_at = Get-Timestamp
        Write-ReleaseJson $ReportPath $result
        throw
    }
}
function Test-ArchivePreflight([string]$TagsValue, [string]$ExpectedDigest, [string]$ArchivePath, $Result, [string]$ReportPath) {
    $tags = @(Get-SelectedReleaseTags $TagsValue)
    if ($env:DOCKER_HUB_USER -or $env:DOCKER_HUB_TOKEN) { throw 'Canonical publication cannot use compatibility Docker credentials.' }
    $Result.expected_digest = Test-DockerArchive $ExpectedDigest $ArchivePath
    $Result.tags = @{}
    foreach ($tag in $tags) { $Result.tags[$tag] = @{ status = 'pending' } }
    Write-ReleaseJson $ReportPath $Result
    $destination = New-Registry 'gratedevs/grate'
    foreach ($tag in $tags) {
        $previous = Get-ExistingDigest $destination $tag
        $Result.tags[$tag].already_present = $previous -ceq $ExpectedDigest
        if ($tag -cne 'latest' -and $null -ne $previous -and $previous -cne $ExpectedDigest) { throw 'Canonical version already has a conflicting digest.' }
    }
    Write-ReleaseJson $ReportPath $Result
    $tags
}
function Confirm-ReleasePreflight([string]$TagsValue, [string]$ExpectedDigest, [string]$ArchivePath, [string]$ReportPath) {
    $result = @{ destination = 'gratedevs/grate'; mode = 'preflight'; status = 'in_progress'; started_at = Get-Timestamp; tags = @{} }
    Write-ReleaseJson $ReportPath $result
    try {
        $null = Test-ArchivePreflight $TagsValue $ExpectedDigest $ArchivePath $result $ReportPath
        foreach ($entry in $result.tags.Values) { $entry.status = 'preflight_verified' }
        $result.status = 'verified'; $result.completed_at = Get-Timestamp
        Write-ReleaseJson $ReportPath $result
        $result
    } catch {
        $result.status = 'failed'; $result.completed_at = Get-Timestamp
        Write-ReleaseJson $ReportPath $result
        throw
    }
}
function Publish-DockerArchive([string]$TagsValue, [string]$ExpectedDigest, [string]$ArchivePath, [string]$AuthPath, [string]$ReportPath) {
    $result = @{ destination = 'gratedevs/grate'; status = 'in_progress'; started_at = Get-Timestamp; tags = @{} }
    Write-ReleaseJson $ReportPath $result
    try {
        if (![IO.File]::Exists($AuthPath)) { throw 'Canonical Docker authentication file is missing.' }
        $tags = @(Test-ArchivePreflight $TagsValue $ExpectedDigest $ArchivePath $result $ReportPath)
        foreach ($tag in $tags) {
            $entry = $result.tags[$tag]
            if (!$entry.already_present) {
                $entry.status = 'copy_started'; Write-ReleaseJson $ReportPath $result
                $null = Invoke-Skopeo @('copy','--all','--preserve-digests','--retry-times','2','--dest-authfile',$AuthPath,"oci-archive:$ArchivePath","docker://docker.io/gratedevs/grate:$tag") 'canonical copy'
                $entry.status = 'copied'; Write-ReleaseJson $ReportPath $result
            }
            Test-CanonicalSource $AuthPath (':' + $tag) $ExpectedDigest
            $entry.status = 'verified'; $entry.digest = $ExpectedDigest; $entry.verified_at = Get-Timestamp
            Write-ReleaseJson $ReportPath $result
        }
        foreach ($tag in $tags) { Test-CanonicalSource $AuthPath (':' + $tag) $ExpectedDigest }
        $result.status = 'verified'; $result.completed_at = Get-Timestamp
        Write-ReleaseJson $ReportPath $result
        $result
    } catch {
        $result.status = 'failed'; $result.completed_at = Get-Timestamp
        Write-ReleaseJson $ReportPath $result
        throw
    }
}
if ($MyInvocation.InvocationName -ne '.') {
    if ($VerifyOnly -and $PreflightOnly) { throw 'Choose -VerifyOnly or -PreflightOnly.' }
    if (!$VerifyOnly -and !$PreflightOnly -and !$Authfile) { throw '-Authfile is required for publication.' }
    try {
        if ($VerifyOnly) { $null = Confirm-DockerArchive $env:EXPECTED_DIGEST $Archive $Report }
        elseif ($PreflightOnly) { $null = Confirm-ReleasePreflight $env:DOCKER_TAGS $env:EXPECTED_DIGEST $Archive $Report }
        else { $null = Publish-DockerArchive $env:DOCKER_TAGS $env:EXPECTED_DIGEST $Archive $Authfile $Report }
    } catch { throw 'Canonical publication failed; inspect the redacted report.' }
}
