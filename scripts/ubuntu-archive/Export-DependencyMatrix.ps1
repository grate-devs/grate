#!/usr/bin/env pwsh
param (
    [Parameter(Mandatory)] [string[]]$AssetsFile,
    [Parameter(Mandatory)] [string]$OutputDirectory,
    [Parameter(Mandatory)] [string]$Profile,
    [Parameter(Mandatory)] [string]$RuntimeIdentifier,
    [string[]]$PackageRoot,
    [string]$LicenseSourceCacheDirectory,
    [string]$SdkRoot
)

$ErrorActionPreference = 'Stop'
$output = [IO.Path]::GetFullPath($OutputDirectory)
New-Item -ItemType Directory -Path $output -Force | Out-Null
$packages = [Collections.Generic.SortedDictionary[string, object]]::new([StringComparer]::OrdinalIgnoreCase)
$sourceCache = @{}
if ($LicenseSourceCacheDirectory) {
    $sourceCache = Get-Content -LiteralPath (Join-Path $LicenseSourceCacheDirectory 'sources.json') -Raw | ConvertFrom-Json -AsHashtable
}

function Get-ContainedFile {
    param (
        [string]$Root,
        [string]$RelativePath
    )

    $prefix = [IO.Path]::GetFullPath($Root) + [IO.Path]::DirectorySeparatorChar
    $path = [IO.Path]::GetFullPath((Join-Path $Root $RelativePath))
    if (!$path.StartsWith($prefix, [StringComparison]::Ordinal) -or !(Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "Missing file or path outside expected directory: $RelativePath"
    }
    return $path
}

foreach ($file in $AssetsFile) {
    $assets = Get-Content -LiteralPath $file -Raw | ConvertFrom-Json -AsHashtable
    if (!$assets.targets -or !$assets.libraries -or !$assets.project.restore.projectName) {
        throw "Not a restored assets file: $file"
    }
    $project = $assets.project.restore.projectName
    $roots = @($PackageRoot) + @($assets.packageFolders.Keys)
    $entries = @{}
    foreach ($entry in $assets.libraries.GetEnumerator()) {
        if ($entry.Value.type -eq 'package') {
            $entries[$entry.Key] = $entry.Value
        }
    }
    foreach ($framework in $assets.project.frameworks.Values) {
        foreach ($download in $framework.downloadDependencies) {
            if ($download.version -notmatch '^\[([^,\[\]]+)(?:,\s*\1)?\]$') {
                throw "Download dependency is not exact: $($download.name) $($download.version)"
            }
            $version = $Matches[1]
            $key = "$($download.name)/$version"
            $entries[$key] = @{
                path = "$($download.name.ToLowerInvariant())/$($version.ToLowerInvariant())"
                download = $true
            }
        }
    }
    foreach ($entry in $entries.GetEnumerator()) {
        if (!$packages.ContainsKey($entry.Key)) {
            $directory = $null
            foreach ($root in $roots) {
                if (!$root) {
                    continue
                }
                $candidate = Join-Path $root $entry.Value.path
                if (Test-Path -LiteralPath $candidate -PathType Container) {
                    $directory = $candidate
                    break
                }
            }
            if (!$directory) {
                throw "Package bytes unavailable for $($entry.Key); pass -PackageRoot for a relocated cache."
            }
            $specs = @(Get-ChildItem -LiteralPath $directory -Filter '*.nuspec' -File)
            if ($specs.Count -ne 1) {
                throw "Expected one nuspec for $($entry.Key)."
            }
            [xml]$spec = Get-Content -LiteralPath $specs[0].FullName -Raw
            $metadata = $spec.package.metadata
            $texts = @()
            $textDirectory = Join-Path $output "texts/$($entry.Key)"
            foreach ($text in Get-ChildItem -LiteralPath $directory -File -Recurse) {
                if ($text.Name -notmatch '^(licen[cs]e|copying|copyright|notice|third[-_. ]?party[-_. ]?notices?)([._-].*)?$') {
                    continue
                }
                $relative = [IO.Path]::GetRelativePath($directory, $text.FullName)
                $target = Join-Path $textDirectory $relative
                New-Item -ItemType Directory -Path (Split-Path -Parent $target) -Force | Out-Null
                Copy-Item -LiteralPath $text.FullName -Destination $target
                $texts += [ordered]@{
                    source = "package:$relative"
                    file = [IO.Path]::GetRelativePath($output, $target)
                    sha256 = (Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash.ToLowerInvariant()
                }
            }
            if ($metadata.license.type -eq 'file') {
                $licenseFile = Get-ContainedFile -Root $directory -RelativePath $metadata.license.InnerText
                if (!(Test-Path -LiteralPath (Join-Path $textDirectory $metadata.license.InnerText))) {
                    $target = Join-Path $textDirectory $metadata.license.InnerText
                    New-Item -ItemType Directory -Path (Split-Path -Parent $target) -Force | Out-Null
                    Copy-Item -LiteralPath $licenseFile -Destination $target
                    $texts += [ordered]@{
                        source = "package:$($metadata.license.InnerText)"
                        file = [IO.Path]::GetRelativePath($output, $target)
                        sha256 = (Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash.ToLowerInvariant()
                    }
                }
            }
            if ($sourceCache.ContainsKey($entry.Key)) {
                $cached = $sourceCache[$entry.Key]
                if ($cached.repositoryCommit -cne [string]$metadata.repository.commit) {
                    throw "Source license cache commit differs from package metadata: $($entry.Key)"
                }
                foreach ($text in $cached.texts) {
                    $source = Get-ContainedFile -Root $LicenseSourceCacheDirectory -RelativePath $text.file
                    if ((Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash.ToLowerInvariant() -cne $text.sha256) {
                        throw "Source license cache hash mismatch: $($entry.Key)"
                    }
                    $target = Join-Path $textDirectory ([IO.Path]::GetFileName($text.file))
                    New-Item -ItemType Directory -Path $textDirectory -Force | Out-Null
                    Copy-Item -LiteralPath $source -Destination $target
                    $texts += [ordered]@{
                        source = $text.url
                        file = [IO.Path]::GetRelativePath($output, $target)
                        sha256 = $text.sha256
                    }
                }
            }
            $provenance = @{}
            $metadataPath = Join-Path $directory '.nupkg.metadata'
            if (Test-Path -LiteralPath $metadataPath) {
                $provenance = Get-Content -LiteralPath $metadataPath -Raw | ConvertFrom-Json -AsHashtable
            }
            $packages[$entry.Key] = [ordered]@{
                id = [string]$metadata.id
                version = [string]$metadata.version
                profile = $Profile
                rid = $RuntimeIdentifier
                frameworks = @()
                licenseType = [string]$metadata.license.type
                license = [string]$metadata.license.InnerText
                authors = [string]$metadata.authors
                copyright = [string]$metadata.copyright
                repository = [string]$metadata.repository.url
                repositoryCommit = [string]$metadata.repository.commit
                sourceFeed = [string]$provenance.source
                packageSha512 = [string]$provenance.contentHash
                matchingSourceBuild = 'unverified: repository metadata is not source-build provenance'
                archiveInput = 'unverified: requires an archive package or reviewed source-built replacement'
                licenseEvidence = if ($texts.Count) { 'texts copied; obligations still require review' } else { 'missing original license text' }
                texts = $texts
                packageNativeFiles = @(Get-ChildItem -LiteralPath $directory -File -Recurse | Where-Object {
                    $_.FullName -match '[/\\]runtimes[/\\].+[/\\]native[/\\]'
                } | ForEach-Object { [IO.Path]::GetRelativePath($directory, $_.FullName) })
                projects = @()
                directInProjects = @()
                downloadDependency = [bool]$entry.Value.download
                targetAssets = @()
            }
        }
        $package = $packages[$entry.Key]
        $package.downloadDependency = $package.downloadDependency -or [bool]$entry.Value.download
        $package.frameworks += @($assets.project.frameworks.Keys)
        $package.projects += $project
        foreach ($framework in $assets.project.frameworks.Values) {
            if ($framework.dependencies.Contains($package.id)) {
                $package.directInProjects += $project
            }
        }
        foreach ($target in $assets.targets.GetEnumerator()) {
            if (!$target.Value.Contains($entry.Key)) {
                continue
            }
            $selection = $target.Value[$entry.Key]
            foreach ($kind in @('compile', 'runtime', 'native', 'runtimeTargets', 'build', 'buildMultiTargeting', 'buildTransitive', 'contentFiles')) {
                if ($selection.Contains($kind)) {
                    $package.targetAssets += [ordered]@{
                        project = $project
                        target = $target.Key
                        kind = $kind
                        files = @($selection[$kind].GetEnumerator() | ForEach-Object {
                            [ordered]@{
                                path = $_.Key
                                metadata = $_.Value
                            }
                        })
                    }
                }
            }
        }
    }
}

$rows = @($packages.Values)
$rows | ForEach-Object {
    $_.projects = @($_.projects | Sort-Object -Unique)
    $_.directInProjects = @($_.directInProjects | Sort-Object -Unique)
    $_.frameworks = @($_.frameworks | Sort-Object -Unique)
}
$rows | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath (Join-Path $output 'dependency-matrix.json') -Encoding utf8NoBOM
$rows | ForEach-Object { [pscustomobject]$_ } | Select-Object id, version, profile, rid, licenseType, license, repository, repositoryCommit, sourceFeed, packageSha512, downloadDependency,
    @{Name = 'frameworks'; Expression = { $_.frameworks -join ';' }},
    @{Name = 'directInProjects'; Expression = { $_.directInProjects -join ';' }},
    @{Name = 'licenseTextFiles'; Expression = { $_.texts.file -join ';' }},
    matchingSourceBuild, archiveInput | Export-Csv -LiteralPath (Join-Path $output 'dependency-matrix.csv') -Encoding utf8NoBOM
if ($SdkRoot) {
    $sdkInputs = @()
    foreach ($category in @('sdk', 'packs')) {
        $categoryPath = Join-Path $SdkRoot $category
        foreach ($directory in Get-ChildItem -LiteralPath $categoryPath -Directory) {
            $sdkInputs += [ordered]@{
                category = $category
                directory = $directory.Name
                versions = if ($category -eq 'packs') { @(Get-ChildItem -LiteralPath $directory.FullName -Directory | ForEach-Object Name) } else { @($directory.Name) }
                archiveInput = 'unverified: record installed distribution package version and source build before archive use'
            }
        }
    }
    $sdkInputs | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $output 'sdk-inputs.json') -Encoding utf8NoBOM
    foreach ($text in Get-ChildItem -LiteralPath $SdkRoot -File) {
        if ($text.Name -match '^(license|third[-_. ]?party[-_. ]?notices?)([._-].*)?$') {
            Copy-Item -LiteralPath $text.FullName -Destination (Join-Path $output "sdk-$($text.Name)")
        }
    }
}
Write-Host "Exported $($rows.Count) package records to $output. This is a restore inventory, not a shipped-file or archive-acceptance claim."
