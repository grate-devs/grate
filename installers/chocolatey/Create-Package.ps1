#!/usr/bin/env pwsh
param(
    [string]$grateExe,
    [Parameter(Mandatory)]
    [ValidatePattern('\A[0-9]+\.[0-9]+\.[0-9]+(?:-[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?\z')]
    [string]$version,
    [ValidateSet('All', 'SQLite', 'SQLServer', 'MariaDB', 'PostgreSQL', 'Oracle')]
    [string]$Distribution = 'All',
    [switch]$AllDistributions,
    [string]$ArtifactDirectory,
    [string]$ReleaseTag = $version,
    [string]$OutputDirectory = $PSScriptRoot
)

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true
. "$PSScriptRoot/Package.Common.ps1"
if (!$ReleaseTag) {
    $ReleaseTag = $version
}
if ($ReleaseTag -cne $version -and $ReleaseTag -cne "v$version") {
    throw 'ReleaseTag must be the package version or the version prefixed with v.'
}
if ($AllDistributions) {
    if ($Distribution -ne 'All' -or $grateExe -or !$ArtifactDirectory) {
        throw 'AllDistributions requires ArtifactDirectory instead of a single executable/profile.'
    }
} elseif ([string]::IsNullOrWhiteSpace($grateExe)) {
    throw 'grateExe is required for a single distribution.'
}
$profiles = if ($AllDistributions) {
    @('All', 'SQLite', 'SQLServer', 'MariaDB', 'PostgreSQL', 'Oracle')
} else {
    @($Distribution)
}
# Validate all requested inputs before producing any package.
$inputs = @(foreach ($name in $profiles) {
    $packageId = if ($name -eq 'All') { 'grate' } else { 'grate-' + $name.ToLowerInvariant() }
    $path = if ($AllDistributions) {
        Join-Path $ArtifactDirectory "$packageId-win-x64-self-contained-$version.zip"
    } else {
        $grateExe
    }
    [pscustomobject]@{
        Distribution = $name
        PackageId = $packageId
        InputPath = (Resolve-Path -LiteralPath $path -ErrorAction Stop).Path
    }
})
$OutputDirectory = [IO.Path]::GetFullPath($OutputDirectory)
New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
$staging = Join-Path ([IO.Path]::GetTempPath()) ('grate-chocolatey-' + [Guid]::NewGuid().ToString('N'))
try {
    foreach ($candidate in $inputs) {
        $packageRoot = Join-Path $staging $candidate.PackageId
        $tools = Join-Path $packageRoot 'tools'
        New-Item -ItemType Directory -Path $tools -Force | Out-Null
        $payload = Join-Path $tools 'grate.exe'
        if ($AllDistributions) {
            $archive = [IO.Compression.ZipFile]::OpenRead($candidate.InputPath)
            try {
                $entry = $archive.GetEntry('grate.exe')
                if (!$entry) {
                    throw "Missing grate.exe in $($candidate.InputPath)."
                }
                $source = $entry.Open()
                $destination = [IO.File]::Create($payload)
                try {
                    $source.CopyTo($destination)
                } finally {
                    $destination.Dispose()
                    $source.Dispose()
                }
            } finally {
                $archive.Dispose()
            }
        } else {
            Copy-Item -LiteralPath $candidate.InputPath -Destination $payload
        }
        $payloadMetadata = [Diagnostics.FileVersionInfo]::GetVersionInfo($payload)
        $identityParameters = @{
            ProductName = $payloadMetadata.ProductName
            ProductVersion = $payloadMetadata.ProductVersion
            Distribution = $candidate.Distribution
            Version = $version
        }
        Assert-ChocolateyPayloadIdentity @identityParameters
        Copy-Item -LiteralPath "$PSScriptRoot/grate/tools/LICENSE.txt" -Destination $tools
        $installScript = Get-Content -LiteralPath "$PSScriptRoot/grate/tools/chocolateyInstall.ps1" -Raw
        $installScript.Replace('@PACKAGE_ID@', $candidate.PackageId) |
            Set-Content -LiteralPath "$tools/chocolateyInstall.ps1" -Encoding utf8NoBOM
        $hash = (Get-FileHash -LiteralPath $payload -Algorithm SHA256).Hash
        $archiveName = "$($candidate.PackageId)-win-x64-self-contained-$version.zip"
        $releaseUrl = "https://github.com/grate-devs/grate/releases/download/$ReleaseTag"
        @"
VERIFICATION
This package embeds the self-contained Windows x64 executable for $($candidate.PackageId) $version.

1. Download the matching upstream archive and checksum list:
   $releaseUrl/$archiveName
   $releaseUrl/checksums.sha256
2. Compare the archive SHA256 with its entry in checksums.sha256 and release-manifest.json.
3. Extract the archive and this .nupkg (a ZIP archive) into separate directories.
4. Compare grate.exe from the archive with tools\grate.exe from the package.
   Both must match this SHA256: $hash
"@ | Set-Content -LiteralPath "$tools/VERIFICATION.txt" -Encoding utf8NoBOM

        [xml]$nuspec = Get-Content -LiteralPath "$PSScriptRoot/grate/grate.nuspec" -Raw
        $nuspec.package.metadata.id = $candidate.PackageId
        $nuspec.package.metadata.version = $version
        if ($candidate.Distribution -ne 'All') {
            $nuspec.package.metadata.title = "grate SQL Migration Runner ($($candidate.Distribution) only)"
            $nuspec.package.metadata.description = @"
# $($candidate.PackageId)

The self-contained Windows x64 grate CLI with $($candidate.Distribution) support.
The installed command is grate. Uninstall another grate Chocolatey variant before selecting this package.

Run grate --help for provider-specific options and https://grate-devs.github.io/grate/ for migration documentation.
"@
        }
        $specification = Join-Path $packageRoot "$($candidate.PackageId).nuspec"
        $nuspec.Save($specification)
        $packArguments = @('pack', "--version=$version", $specification, "--outputdirectory=$OutputDirectory")
        Push-Location $packageRoot
        try {
            & choco @packArguments
            if ($LASTEXITCODE -ne 0) {
                throw "choco pack failed with exit code $LASTEXITCODE."
            }
        } finally {
            Pop-Location
        }
    }
} finally {
    Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction SilentlyContinue
}
