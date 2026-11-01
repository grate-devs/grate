#!/usr/bin/env pwsh

param (
    [string]$grateExe, # Kept for the common Create-Installer.ps1 interface.
    [Parameter(Mandatory=$true)] [string]$version,
    [string]$releaseTag = $version,
    [string]$wingetCreate = 'wingetcreate',
    [string]$outputDirectory = (Join-Path $PSScriptRoot 'artifacts'),
    [switch]$PrepareMigration
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# A GitVersion release flag alone also admits prereleases. Reject them here,
# independently of workflow conditions, before invoking any external tool.
if ($version -cnotmatch '^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$' -or
    $releaseTag -cnotin @($version, "v$version")) {
    throw 'WinGet requires a stable three-part version and its matching release tag.'
}
$requestHeaders = @{ Accept = 'application/vnd.github+json' }
if ($env:GH_TOKEN) { $requestHeaders.Authorization = "Bearer $env:GH_TOKEN" }
$release = Invoke-RestMethod -Uri "https://api.github.com/repos/grate-devs/grate/releases/tags/$releaseTag" -Headers $requestHeaders
if ($release.draft -or $release.prerelease -or $release.tag_name -cne $releaseTag) {
    throw 'WinGet requires a published stable GitHub release with the requested tag.'
}

# Use the release inventory, rather than inventing URLs. Old releases used other
# layouts (for example grate-1.2.0.msi); do not silently create broken manifests.
$urls = foreach ($asset in @(
    @{ Name = "grate-win-x86-self-contained-$version.zip"; Architecture = 'x86' },
    @{ Name = "grate-win-x64-self-contained-$version.zip"; Architecture = 'x64' },
    @{ Name = "grate-win-arm64-self-contained-$version.zip"; Architecture = 'arm64' },
    @{ Name = "grate-msi-win-x64-$version.msi"; Architecture = 'x64' },
    @{ Name = "grate-msi-win-arm64-$version.msi"; Architecture = 'arm64' }
)) {
    $matchingAssets = @($release.assets | Where-Object name -CEQ $asset.Name)
    if ($matchingAssets.Count -ne 1 -or $matchingAssets[0].state -ne 'uploaded' -or $matchingAssets[0].size -le 0) {
        throw "Expected exactly one uploaded, nonempty release asset: $($asset.Name)."
    }
    $url = $matchingAssets[0].browser_download_url
    $expected = "https://github.com/grate-devs/grate/releases/download/$releaseTag/$($asset.Name)"
    if ($url -cne $expected) { throw "Unexpected download URL for $($asset.Name): $url" }
    "$url|$($asset.Architecture)"
}

# update requires an existing upstream identity. Initial migration candidates
# explicitly start with erikbra.grate, then convert a private copy. Never submit
# from this helper; neither generation nor schema validation proves migration.
$sourceId = 'erikbra.grate'
$targetId = if ($PrepareMigration) { 'grate-devs.grate' } else { $sourceId }
$partition = if ($PrepareMigration) { 'g/grate-devs' } else { 'e/erikbra' }
$destination = Join-Path $outputDirectory "manifests/$partition/grate/$version"
if (Test-Path -LiteralPath $destination) { throw "Refusing to overwrite manifests: $destination" }
$temporary = Join-Path ([IO.Path]::GetTempPath()) ("grate-winget-" + [Guid]::NewGuid().ToString('N'))
try {
    New-Item -ItemType Directory -Path $temporary | Out-Null
    & $wingetCreate update $sourceId -u $urls -v $version -o $temporary --release-notes-url "https://github.com/grate-devs/grate/releases/tag/$releaseTag" --release-date ([datetime]$release.published_at).ToString('yyyy-MM-dd')
    if ($LASTEXITCODE -ne 0) { throw "wingetcreate failed with exit code $LASTEXITCODE." }
    $source = Join-Path $temporary "manifests/e/erikbra/grate/$version"
    $files = @("$sourceId.yaml", "$sourceId.installer.yaml", "$sourceId.locale.en-US.yaml")
    $prepared = foreach ($name in $files) {
        $content = Get-Content -LiteralPath (Join-Path $source $name) -Raw
        if ($content -cnotmatch "(?m)^PackageIdentifier: $([regex]::Escape($sourceId))\r?$" -or
            $content -cnotmatch "(?m)^PackageVersion: $([regex]::Escape($version))\r?$") {
            throw "Unexpected package identity/version in wingetcreate output: $name"
        }
        if ($PrepareMigration) {
            $content = $content -creplace "(?m)^PackageIdentifier: $([regex]::Escape($sourceId))\r?$", "PackageIdentifier: $targetId"
            if ($name -eq "$sourceId.locale.en-US.yaml") {
                # Display publisher only. The actual MSI ARP publisher, codes,
                # paths and upgrade behavior must retain their inspected values.
                if ($content -cnotmatch '(?m)^Publisher: erikbra\r?$') { throw 'Review the changed upstream publisher before preparing migration.' }
                $content = $content -creplace '(?m)^Publisher: erikbra\r?$', 'Publisher: grate-devs'
            }
        }
        @{ Name = $name.Replace($sourceId, $targetId); Content = $content }
    }
    New-Item -ItemType Directory -Path $destination -Force | Out-Null
    foreach ($file in $prepared) {
        Set-Content -LiteralPath (Join-Path $destination $file.Name) -Value $file.Content -Encoding utf8NoBOM -NoNewline
    }
    Write-Host "Prepared $targetId $version in $destination. Submission is a separate step."
    if ($PrepareMigration) { Write-Warning 'Local candidate only: upstream acceptance and Windows migration/correlation verification are still required.' }
} finally {
    Remove-Item -LiteralPath $temporary -Recurse -Force -ErrorAction SilentlyContinue
}
