. "$PSScriptRoot/release_common.ps1"
function Get-SelectedReleaseTags([string]$Value) {
    $names = @{ 'gratedevs/grate' = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal); 'erikbra/grate' = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal) }
    $lines = @($Value -split '\r?\n')
    if ($lines.Count -gt 0 -and $lines[-1] -ceq '') { $lines = @($lines | Select-Object -SkipLast 1) }
    foreach ($line in $lines) {
        if ($line -cnotmatch '\A(gratedevs/grate|erikbra/grate):([A-Za-z0-9_][A-Za-z0-9_.-]{0,127})\z') { throw 'Unexpected release image reference.' }
        if (!$names[$Matches[1]].Add($Matches[2])) { throw 'Duplicate release image reference.' }
    }
    if ($names['gratedevs/grate'].Count -eq 0 -or !$names['gratedevs/grate'].SetEquals($names['erikbra/grate'])) { throw 'Canonical and compatibility release tags must match exactly.' }
    $versions = @($names['gratedevs/grate'] | Where-Object { $_ -cne 'latest' })
    if ($versions.Count -ne 1) { throw 'Exactly one version tag is required.' }
    if ($versions[0] -cnotmatch '\A[0-9]+\.[0-9]+\.[0-9]+(?:-[A-Za-z0-9.-]+)?\z') { throw 'A release version tag is required.' }
    if ($versions[0].Contains('-') -and $names['gratedevs/grate'].Contains('latest')) { throw 'Prereleases cannot update latest.' }
    Sort-ReleaseTags $names['gratedevs/grate']
}
function Test-CanonicalSource([string]$SourceAuthfile, [string]$Reference, [string]$ExpectedDigest) {
    $raw = Invoke-Skopeo @('inspect','--raw','--authfile',$SourceAuthfile,"docker://docker.io/gratedevs/grate$Reference") 'source inspection'
    if ((Get-ByteDigest $raw) -cne $ExpectedDigest) { throw 'Canonical release reference differs from the build digest.' }
}
function Copy-DockerRelease([string]$TagsValue, [string]$ExpectedDigest, [string]$SourceAuthfile, [string]$ReportPath, [string]$User, [string]$Secret) {
    $result = @{ source = 'gratedevs/grate'; destination = 'erikbra/grate'; status = 'in_progress'; started_at = Get-Timestamp; tags = @{} }
    Write-ReleaseJson $ReportPath $result
    try {
        $tags = @(Get-SelectedReleaseTags $TagsValue)
        if ($ExpectedDigest -cnotmatch '\Asha256:[a-f0-9]{64}\z') { throw 'EXPECTED_DIGEST must be a SHA256 image digest.' }
        if (!$User -or !$Secret) { throw 'Compatibility publishing requires both Docker credential variables.' }
        if (![IO.File]::Exists($SourceAuthfile)) { throw 'Canonical Docker authentication file is missing.' }
        $result.expected_digest = $ExpectedDigest
        $destination = New-Registry 'erikbra/grate'
        Test-CanonicalSource $SourceAuthfile ('@' + $ExpectedDigest) $ExpectedDigest
        foreach ($tag in $tags) {
            Test-CanonicalSource $SourceAuthfile (':' + $tag) $ExpectedDigest
            $previous = Get-ExistingDigest $destination $tag
            if ($tag -cne 'latest' -and $null -ne $previous -and $previous -cne $ExpectedDigest) { throw 'Compatibility version already has a conflicting digest.' }
            $result.tags[$tag] = @{ status = 'pending'; already_present = $previous -ceq $ExpectedDigest }
        }
        Write-ReleaseJson $ReportPath $result
        $directory = Join-Path ([IO.Path]::GetTempPath()) ('grate-compatibility-auth-' + [Guid]::NewGuid().ToString('N'))
        try {
            $authfile = New-PrivateAuthFile $directory $User $Secret
            foreach ($tag in $tags) {
                $entry = $result.tags[$tag]
                if (!$entry.already_present) {
                    $entry.status = 'copy_started'
                    Write-ReleaseJson $ReportPath $result
                    $null = Invoke-Skopeo @('copy','--all','--preserve-digests','--retry-times','2','--src-authfile',$SourceAuthfile,'--dest-authfile',$authfile,"docker://docker.io/gratedevs/grate@$ExpectedDigest","docker://docker.io/erikbra/grate:$tag") 'compatibility copy'
                    $entry.status = 'copied'
                    Write-ReleaseJson $ReportPath $result
                }
                $actual = Get-RegistryDescription $destination $tag -CheckBlobs
                if ($actual.digest -cne $ExpectedDigest) { throw 'Compatibility manifest differs from the build digest.' }
                foreach ($key in $actual.Keys) { $entry[$key] = $actual[$key] }
                $entry.status = 'verified'; $entry.verified_at = Get-Timestamp
                Write-ReleaseJson $ReportPath $result
            }
        } finally { if ([IO.Directory]::Exists($directory)) { [IO.Directory]::Delete($directory, $true) } }
        foreach ($tag in $tags) {
            Test-CanonicalSource $SourceAuthfile (':' + $tag) $ExpectedDigest
            if ((Get-RegistryDigest $destination $tag) -cne $ExpectedDigest) { throw 'Compatibility release reference changed during copying.' }
        }
        $result.status = 'verified'; $result.completed_at = Get-Timestamp
        Write-ReleaseJson $ReportPath $result
        $result
    } catch {
        $result.status = 'failed'; $result.completed_at = Get-Timestamp
        Write-ReleaseJson $ReportPath $result
        throw
    }
}
