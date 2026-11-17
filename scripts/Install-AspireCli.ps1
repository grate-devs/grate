#!/usr/bin/env pwsh
# Pin the native CLI/bundle without changing a user's installation.
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$Destination,
    [ValidateSet('linux-x64', 'osx-arm64')]
    [string]$RuntimeIdentifier = 'linux-x64'
)

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true
$version = '13.6.5'
$destinationPath = [IO.Path]::GetFullPath($Destination)
if (Test-Path -LiteralPath $destinationPath) {
    throw "Use a new directory for the pinned Aspire installation: $destinationPath"
}
$download = Join-Path ([IO.Path]::GetTempPath()) "grate-aspire-cli-$([Guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Path $download | Out-Null
try {
    $name = "aspire-cli-$RuntimeIdentifier-$version.tar.gz"
    $url = "https://github.com/microsoft/aspire/releases/download/v$version/$name"
    $archive = Join-Path $download $name
    $checksum = "$archive.sha512"
    Invoke-WebRequest -Uri "$url.sha512" -OutFile $checksum
    Invoke-WebRequest -Uri $url -OutFile $archive
    $expected = ((Get-Content -LiteralPath $checksum -Raw).Trim() -split '\s+')[0]
    if ($expected -notmatch '^[0-9a-fA-F]{128}$' -or
        (Get-FileHash -LiteralPath $archive -Algorithm SHA512).Hash -ine $expected) {
        throw 'The Aspire release archive does not match its SHA512 checksum.'
    }
    New-Item -ItemType Directory -Path $destinationPath | Out-Null
    tar -xzf $archive -C $destinationPath
    $cli = Join-Path $destinationPath 'aspire'
    $actualVersion = (& $cli --version).Trim()
    if ($actualVersion -notmatch '^13\.6\.5(\+|$)') {
        throw "Unexpected Aspire CLI version: $actualVersion"
    }
    # Resolve the bundle before parallel AppHost builds; implicit DNX setup
    # failed on clean CI. Keep discovery and extraction in one isolated home.
    $start = [Diagnostics.ProcessStartInfo]::new($cli)
    $start.UseShellExecute = $false
    $start.Environment['ASPIRE_HOME'] = $destinationPath
    foreach ($argument in @('setup', '--install-path', $destinationPath)) {
        $start.ArgumentList.Add($argument)
    }
    $process = [Diagnostics.Process]::Start($start)
    try {
        $process.WaitForExit()
        if ($process.ExitCode -ne 0) {
            throw "Aspire bundle setup failed with exit code $($process.ExitCode)."
        }
    }
    finally {
        $process.Dispose()
    }
    foreach ($component in @('managed', 'dashboard', 'dcp')) {
        if (!(Test-Path -LiteralPath (Join-Path $destinationPath "bundle/$component") -PathType Container)) {
            throw "Aspire bundle component is missing: $component"
        }
    }
    [pscustomobject]@{
        CliPath = $cli
        BundlePath = $destinationPath
    }
}
finally {
    Remove-Item -LiteralPath $download -Recurse -Force
}
