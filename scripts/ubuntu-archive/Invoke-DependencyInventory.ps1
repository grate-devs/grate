#!/usr/bin/env pwsh
param (
    [Parameter(Mandatory)] [string]$OutputDirectory,
    [Parameter(Mandatory)] [switch]$AllowOnlineRestore,
    [string]$RepositoryRoot = (Join-Path $PSScriptRoot '../..'),
    [string]$SdkImage = 'mcr.microsoft.com/dotnet/sdk:11.0.100-rc.3',
    [string]$LicenseSourceCacheDirectory
)

$ErrorActionPreference = 'Stop'
if (!$AllowOnlineRestore) {
    throw 'This discovery inventory uses NuGet.org. Pass -AllowOnlineRestore; it does not demonstrate an archive-qualified offline build.'
}
$repository = (Resolve-Path -LiteralPath $RepositoryRoot).Path
$output = [IO.Path]::GetFullPath($OutputDirectory)
if (Test-Path -LiteralPath $output) {
    throw "Use a new output directory so no developer package or restore cache is reused: $output"
}
New-Item -ItemType Directory -Path $output | Out-Null
$sourceCommit = & git -C $repository rev-parse HEAD
if ($LASTEXITCODE -ne 0) {
    throw 'Cannot identify source commit.'
}
# Inventory committed source deliberately; uncommitted working files are not build inputs.
& git -C $repository archive --format=tar -o (Join-Path $output 'source.tar') HEAD
if ($LASTEXITCODE -ne 0) {
    throw 'Cannot snapshot committed source.'
}
$imageMetadata = & docker image inspect $SdkImage
if ($LASTEXITCODE -ne 0) {
    throw "Pull the selected SDK image before running this discovery inventory: $SdkImage"
}
$manifest = [ordered]@{
    sourceCommit = $sourceCommit
    sourceArchiveSha256 = (Get-FileHash -LiteralPath (Join-Path $output 'source.tar') -Algorithm SHA256).Hash.ToLowerInvariant()
    imageRequested = $SdkImage
    image = @($imageMetadata | ConvertFrom-Json -AsHashtable)
    network = 'enabled only for dependency discovery; not an archive source build'
    packageFeed = 'https://api.nuget.org/v3/index.json'
    licenseCache = if ($LicenseSourceCacheDirectory) { 'explicit read-only audit cache; matching source commit/hash validated per text' } else { 'not supplied; original texts may be missing' }
}
$manifest | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath (Join-Path $output 'run-manifest.json') -Encoding utf8NoBOM
$arguments = @(
    'run', '--rm',
    '--mount', "type=bind,src=$output,dst=/evidence",
    '--mount', "type=bind,src=$PSScriptRoot,dst=/automation,readonly",
    '--workdir', '/evidence',
    '--env', 'NUGET_PACKAGES=/evidence/packages',
    '--env', 'NUGET_HTTP_CACHE_PATH=/evidence/http-cache',
    '--env', 'DOTNET_CLI_HOME=/evidence/cli-home'
)
if ($LicenseSourceCacheDirectory) {
    $cache = (Resolve-Path -LiteralPath $LicenseSourceCacheDirectory).Path
    $arguments += @('--mount', "type=bind,src=$cache,dst=/audit,readonly")
}
$arguments += @($SdkImage, 'pwsh', '-NoProfile', '-File', '/automation/Restore-DependencyInventory.ps1')
if ($LicenseSourceCacheDirectory) {
    $arguments += @('-LicenseSourceCacheDirectory', '/audit')
}
& docker @arguments
if ($LASTEXITCODE -ne 0) {
    throw "Dependency inventory failed. Partial logs are retained in $output."
}
