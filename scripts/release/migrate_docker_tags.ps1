#!/usr/bin/env pwsh
[CmdletBinding()]
param([string]$ReportDir, [string]$Plan, [switch]$Copy, [switch]$Verify)
. "$PSScriptRoot/release_common.ps1"
function Get-DockerMigrationSnapshot($Source, $Destination) {
    $tags = @(Get-DockerTagNames 'erikbra/grate')
    if (!$tags.Count) { throw 'Source has no tags.' }
    $destinationTags = @(Get-DockerTagNames 'gratedevs/grate')
    $snapshot = @{ source = 'erikbra/grate'; destination = 'gratedevs/grate'; created_at = Get-Timestamp; tags = [Collections.Hashtable]::new([StringComparer]::Ordinal); destination_before = [Collections.Hashtable]::new([StringComparer]::Ordinal) }
    foreach ($tag in $tags) { $snapshot.tags[$tag] = Get-RegistryDescription $Source $tag; Write-Host "Snapshot ${tag}: $($snapshot.tags[$tag].digest)" }
    foreach ($tag in $destinationTags) { $snapshot.destination_before[$tag] = Get-RegistryDescription $Destination $tag }
    foreach ($tag in $tags) {
        if ($snapshot.destination_before.ContainsKey($tag) -and !(Test-JsonEqual $snapshot.tags[$tag] $snapshot.destination_before[$tag])) { throw "Destination tag conflicts with source: $tag" }
    }
    $snapshot
}
function Test-MigrationSource($Snapshot, $Source) {
    $inventory = [Collections.Generic.HashSet[string]]::new([string[]]@(Get-DockerTagNames 'erikbra/grate'), [StringComparer]::Ordinal)
    if (!$inventory.SetEquals([string[]]@($Snapshot.tags.Keys))) { throw 'Source tag inventory changed since the snapshot.' }
    foreach ($tag in $Snapshot.tags.Keys) {
        if ((Get-RegistryDigest $Source $tag) -cne $Snapshot.tags[$tag].digest) { throw "Source tag moved since the snapshot: $tag" }
    }
}
function Copy-AndVerifyDockerHistory($Snapshot, $Source, $Destination, [string]$ReportPath, [scriptblock]$CopyImage) {
    Test-MigrationSource $Snapshot $Source
    $existing = [Collections.Generic.HashSet[string]]::new([string[]]@(Get-DockerTagNames 'gratedevs/grate'), [StringComparer]::Ordinal)
    foreach ($tag in $Snapshot.tags.Keys) {
        if ($existing.Contains($tag) -and !(Test-JsonEqual (Get-RegistryDescription $Destination $tag) $Snapshot.tags[$tag])) { throw "Refusing to overwrite a conflicting destination tag: $tag" }
    }
    $result = @{ source = 'erikbra/grate'; destination = 'gratedevs/grate'; started_at = Get-Timestamp; status = 'in_progress'; tags = [Collections.Hashtable]::new([StringComparer]::Ordinal) }
    Write-ReleaseJson $ReportPath $result
    try {
        foreach ($tag in @(Sort-ReleaseTags $Snapshot.tags.Keys)) {
            $expected = $Snapshot.tags[$tag]
            if (!$existing.Contains($tag)) { & $CopyImage $expected.digest $tag }
            $actual = Get-RegistryDescription $Destination $tag -CheckBlobs
            if (!(Test-JsonEqual $actual $expected)) { throw "Destination manifest graph/platform mismatch: $tag" }
            $entry = @{ action = $(if ($existing.Contains($tag)) { 'already_present' } else { 'copied' }); verified_at = Get-Timestamp }
            foreach ($key in $actual.Keys) { $entry[$key] = $actual[$key] }
            $result.tags[$tag] = $entry
            Write-ReleaseJson $ReportPath $result
            Write-Host "Verified ${tag}: $($actual.digest)"
        }
        Test-MigrationSource $Snapshot $Source
        foreach ($tag in $Snapshot.tags.Keys) { if ((Get-RegistryDigest $Destination $tag) -cne $Snapshot.tags[$tag].digest) { throw "Destination tag moved during copying: $tag" } }
        $result.status = 'verified'; $result.completed_at = Get-Timestamp
        Write-ReleaseJson $ReportPath $result
        $result
    } catch {
        $result.status = 'failed'; $result.completed_at = Get-Timestamp
        Write-ReleaseJson $ReportPath $result
        throw
    }
}
function Invoke-DockerMigration([string]$Directory, [string]$PlanPath, [bool]$ShouldCopy, [bool]$VerifyOnly) {
    if ($ShouldCopy -and $VerifyOnly) { throw 'Choose -Copy or -Verify.' }
    if (!$Directory) { throw '-ReportDir is required.' }
    $source = New-Registry 'erikbra/grate'; $destination = New-Registry 'gratedevs/grate'
    $snapshot = if ($PlanPath) { Get-Content -LiteralPath $PlanPath -Raw | ConvertFrom-Json -AsHashtable } else { Get-DockerMigrationSnapshot $source $destination }
    if ($snapshot.source -cne 'erikbra/grate' -or $snapshot.destination -cne 'gratedevs/grate') { throw 'Unexpected migration endpoints.' }
    Write-ReleaseJson (Join-Path $Directory 'plan.json') $snapshot
    if (!$ShouldCopy -and !$VerifyOnly) { return }
    if ($VerifyOnly) {
        $null = Copy-AndVerifyDockerHistory $snapshot $source $destination (Join-Path $Directory 'verification.json') { param($Digest,$Tag) throw "Destination tag is absent: $Tag" }
        return
    }
    if (!$env:DOCKER_HUB_USER -or !$env:DOCKER_HUB_TOKEN -or !(Get-Command skopeo -ErrorAction SilentlyContinue)) { throw 'Copy requires both CI credentials and skopeo.' }
    $authDirectory = Join-Path ([IO.Path]::GetTempPath()) ('grate-registry-auth-' + [Guid]::NewGuid().ToString('N'))
    try {
        $authfile = New-PrivateAuthFile $authDirectory $env:DOCKER_HUB_USER $env:DOCKER_HUB_TOKEN
        $null = Copy-AndVerifyDockerHistory $snapshot $source $destination (Join-Path $Directory 'copy-result.json') {
            param($Digest,$Tag)
            $null = Invoke-Skopeo @('copy','--all','--preserve-digests','--retry-times','2','--authfile',$authfile,"docker://docker.io/erikbra/grate@$Digest","docker://docker.io/gratedevs/grate:$Tag") 'historical copy'
        }
    } finally { if ([IO.Directory]::Exists($authDirectory)) { [IO.Directory]::Delete($authDirectory, $true) } }
}
if ($MyInvocation.InvocationName -ne '.') {
    try { Invoke-DockerMigration $ReportDir $Plan $Copy.IsPresent $Verify.IsPresent }
    catch { throw 'Migration stopped; inspect the redacted report. No credential details logged.' }
}
