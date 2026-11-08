#!/usr/bin/env pwsh
param (
    [Parameter(Mandatory)]
    [ValidateSet('tenacious', 'resolute', 'noble', 'jammy')]
    [string]$Suite,

    [Parameter(Mandatory)]
    [ValidateSet('amd64', 'arm64')]
    [string]$Architecture,

    [Parameter(Mandatory)]
    [string]$OutputDirectory,

    [string]$UbuntuImage = 'ubuntu:26.04'
)

$ErrorActionPreference = 'Stop'
$output = [IO.Path]::GetFullPath($OutputDirectory)
New-Item -ItemType Directory -Path $output -Force | Out-Null

# Provisioning/querying uses networking. It is deliberately separate from the
# isolated source build and never populates its NuGet input feed.
$command = @'
set -eu
cat /etc/os-release
dpkg --print-architecture
test -f /etc/apt/sources.list.d/ubuntu.sources
. /etc/os-release
test -n "${VERSION_CODENAME:-}"
sed -i "s/$VERSION_CODENAME/@SUITE@/g" /etc/apt/sources.list.d/ubuntu.sources
cat /etc/apt/sources.list.d/ubuntu.sources
apt-get update
apt-cache policy dotnet-sdk-11.0 dotnet-sdk-11.0-source-built-artifacts dotnet-runtime-11.0 dotnet-apphost-pack-11.0 dotnet-targeting-pack-11.0 dotnet-sdk-10.0 dotnet-sdk-10.0-source-built-artifacts dotnet-runtime-10.0 dotnet-apphost-pack-10.0 dotnet-targeting-pack-10.0
apt-cache search 'dapper|mysqlconnector|system.commandline|dotnet.*artifact'
'@.Replace('@SUITE@', $Suite)

$arguments = @(
    'run', '--rm', '--platform', "linux/$Architecture",
    $UbuntuImage, 'sh', '-ec', $command
)
& docker @arguments 2>&1 | Tee-Object -FilePath (Join-Path $output 'apt-candidates.log')
$queryExitCode = $LASTEXITCODE
& docker image inspect --platform "linux/$Architecture" $UbuntuImage --format '{{json .}}' |
    Set-Content -LiteralPath (Join-Path $output 'image.json') -Encoding utf8NoBOM
if ($LASTEXITCODE -ne 0) {
    throw 'Could not capture the queried image identity.'
}

@{
    observedUtc = [DateTime]::UtcNow.ToString('o')
    suite = $Suite
    architecture = $Architecture
    baseImage = $UbuntuImage
    command = @('docker') + $arguments
    queryExitCode = $queryExitCode
    scope = 'APT index query only; no package installation, build or runtime test'
} | ConvertTo-Json -Depth 6 |
    Set-Content -LiteralPath (Join-Path $output 'query.json') -Encoding utf8NoBOM

if ($queryExitCode -ne 0) {
    throw "Archive query failed with exit code $queryExitCode; inspect apt-candidates.log."
}
Write-Host "Saved archive observations in $output. Search results do not establish matching-source or build-feed availability."
