#!/usr/bin/env pwsh

param (
    [string]$grateExe, # Kept for the common Create-Installer.ps1 interface.
    [Parameter(Mandatory=$true)] [string]$version,
    [string]$releaseTag = $version,
    [string]$wingetCreate = 'wingetcreate',
    [string]$outputDirectory = (Join-Path $PSScriptRoot 'artifacts'),
    [switch]$PrepareMigration,
    [string]$MsiMetadataReader = (Join-Path (Split-Path $PSScriptRoot) 'msi/Get-InstallerMetadata.ps1')
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'MigrationManifestPolicy.ps1')

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
$releaseAssets = @(
    @{ Name = "grate-win-x86-self-contained-$version.zip"; Architecture = 'x86' },
    @{ Name = "grate-win-x64-self-contained-$version.zip"; Architecture = 'x64' },
    @{ Name = "grate-win-arm64-self-contained-$version.zip"; Architecture = 'arm64' },
    @{ Name = "grate-msi-win-x64-$version.msi"; Architecture = 'x64' },
    @{ Name = "grate-msi-win-arm64-$version.msi"; Architecture = 'arm64' }
)
$urls = foreach ($asset in $releaseAssets) {
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
$destinations = @((Join-Path $outputDirectory "manifests/e/erikbra/grate/$version"))
if ($PrepareMigration) { $destinations += Join-Path $outputDirectory "manifests/g/grate-devs/grate/$version" }
foreach ($destination in $destinations) {
    if (Test-Path -LiteralPath $destination) { throw "Refusing to overwrite manifests: $destination" }
}
$temporary = Join-Path ([IO.Path]::GetTempPath()) ("grate-winget-" + [Guid]::NewGuid().ToString('N'))
$created = @()
try {
    New-Item -ItemType Directory -Path $temporary | Out-Null
    $msiMetadata = @()
    if ($PrepareMigration) {
        foreach ($asset in @($releaseAssets | Where-Object Name -Like '*.msi')) {
            $published = @($release.assets | Where-Object name -CEQ $asset.Name)[0]
            if ($published.digest -cnotmatch '^sha256:[a-f0-9]{64}$') { throw 'Migration requires published SHA256 release digests for both MSIs.' }
            $localMsi = Join-Path $temporary $asset.Name
            Invoke-WebRequest -Uri $published.browser_download_url -OutFile $localMsi
            $hash = (Get-FileHash -LiteralPath $localMsi -Algorithm SHA256).Hash
            if ("sha256:$($hash.ToLowerInvariant())" -cne $published.digest) { throw 'Downloaded migration MSI does not match its release digest.' }
            $actual = & $MsiMetadataReader -MsiPath $localMsi
            $msiMetadata += [pscustomobject]@{
                Architecture=$asset.Architecture; InstallerUrl=$published.browser_download_url; Sha256=$hash
                ProductCode=$actual.ProductCode; UpgradeCode=$actual.UpgradeCode; Manufacturer=$actual.Manufacturer
                ProductName=$actual.ProductName; ProductVersion=$actual.ProductVersion; Platform=$actual.Platform
            }
        }
        # Reject legacy releases before generating a new identity. Successful
        # YAML conversion cannot turn an uncorrected MSI into a migration.
        Assert-WinGetMigrationMetadata $msiMetadata $version (Join-Path (Split-Path $PSScriptRoot) 'msi/identity-contract.json')
    }
    & $wingetCreate update $sourceId -u $urls -v $version -o $temporary --release-notes-url "https://github.com/grate-devs/grate/releases/tag/$releaseTag" --release-date ([datetime]$release.published_at).ToString('yyyy-MM-dd')
    if ($LASTEXITCODE -ne 0) { throw "wingetcreate failed with exit code $LASTEXITCODE." }
    $source = Join-Path $temporary "manifests/e/erikbra/grate/$version"
    $files = @("$sourceId.yaml", "$sourceId.installer.yaml", "$sourceId.locale.en-US.yaml")
    $contents = @{}
    foreach ($name in $files) {
        $content = Get-Content -LiteralPath (Join-Path $source $name) -Raw
        if ($content -cnotmatch "(?m)^PackageIdentifier: $([regex]::Escape($sourceId))\r?$" -or
            $content -cnotmatch "(?m)^PackageVersion: $([regex]::Escape($version))\r?$") {
            throw "Unexpected package identity/version in wingetcreate output: $name"
        }
        $contents[$name] = $content
    }
    $sets = @(@{ Id=$sourceId; Destination=$destinations[0]; Contents=$contents })
    if ($PrepareMigration) {
        $policy = ConvertTo-WinGetMigrationManifests -InstallerYaml $contents["$sourceId.installer.yaml"] -Version $version -MsiMetadata $msiMetadata
        $contents["$sourceId.installer.yaml"] = $policy.BridgeInstallerYaml
        $locale = $contents["$sourceId.locale.en-US.yaml"]
        if ($locale -cnotmatch '(?m)^Publisher: (?:erikbra|grate-devs)\r?$') { throw 'Review the changed upstream publisher before preparing migration.' }
        $contents["$sourceId.locale.en-US.yaml"] = $locale -creplace '(?m)^Publisher: (?:erikbra|grate-devs)\r?$', 'Publisher: erikbra'
        $newContents = @{}
        foreach ($name in $files) {
            $newContents[$name] = $contents[$name] -creplace '(?m)^PackageIdentifier: erikbra\.grate\r?$', 'PackageIdentifier: grate-devs.grate'
        }
        $newContents["$sourceId.installer.yaml"] = $policy.NewInstallerYaml
        $newContents["$sourceId.locale.en-US.yaml"] = $newContents["$sourceId.locale.en-US.yaml"] -creplace '(?m)^Publisher: erikbra\r?$', 'Publisher: grate-devs'
        $sets += @{ Id='grate-devs.grate'; Destination=$destinations[1]; Contents=$newContents }
    }
    foreach ($set in $sets) {
        New-Item -ItemType Directory -Path $set.Destination -Force | Out-Null
        $created += $set.Destination
        foreach ($name in $files) {
            Set-Content -LiteralPath (Join-Path $set.Destination $name.Replace($sourceId, $set.Id)) -Value $set.Contents[$name] -Encoding utf8NoBOM -NoNewline
        }
        Write-Host "Prepared $($set.Id) $version in $($set.Destination). Submission is a separate step."
    }
    if ($PrepareMigration) { Write-Warning 'Local candidate only: upstream acceptance and Windows migration/correlation verification are still required.' }
} catch {
    foreach ($destination in $created) { Remove-Item -LiteralPath $destination -Recurse -Force -ErrorAction SilentlyContinue }
    throw
} finally {
    Remove-Item -LiteralPath $temporary -Recurse -Force -ErrorAction SilentlyContinue
}
