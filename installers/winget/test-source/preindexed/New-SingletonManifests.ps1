#!/usr/bin/env pwsh
# JSON flow syntax is valid YAML. Every indexed path points at one complete
# singleton stream so the V2 index records the actual downloadable stream hash.
param([Parameter(Mandatory)][string]$Catalog,[Parameter(Mandatory)][string]$OutputDirectory)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$inputCatalog=Get-Content -LiteralPath $Catalog -Raw | ConvertFrom-Json -AsHashtable
New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
$paths=@()
$seen=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
foreach ($package in $inputCatalog.Packages) {
    if ($package.PackageIdentifier -notmatch '^[A-Za-z0-9.-]+$') { throw 'Unsafe package identifier.' }
    foreach ($version in $package.Versions) {
        if ($version.PackageVersion -notmatch '^\d+\.\d+\.\d+$') { throw 'Only stable triplet fixtures are supported.' }
        $key="$($package.PackageIdentifier)-$($version.PackageVersion)"
        if (!$seen.Add($key)) { throw "Duplicate manifest identity $key" }
        $manifest=[ordered]@{
            PackageIdentifier=$package.PackageIdentifier
            PackageVersion=$version.PackageVersion
        }
        foreach ($field in $version.DefaultLocale.Keys) { $manifest[$field]=$version.DefaultLocale[$field] }
        $manifest.Installers=$version.Installers
        $manifest.ManifestType='singleton'
        $manifest.ManifestVersion='1.12.0'
        $path=Join-Path $OutputDirectory "$key.yaml"
        $manifest | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $path -Encoding utf8NoBOM
        $paths+=$path
    }
}
if (!$paths.Count) { throw 'The source requires at least one manifest.' }
$paths
