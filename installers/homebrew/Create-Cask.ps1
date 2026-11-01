#!/usr/bin/env pwsh

param (
    [Parameter(Mandatory=$true)]
    [ValidatePattern('\A[0-9]+\.[0-9]+\.[0-9]+\z')]
    [string]$version,
    [Parameter(Mandatory=$true)] [string]$artifactDirectory,
    [string]$releaseTag = $version,
    [string]$outputPath = (Join-Path $PSScriptRoot '../../artifacts/homebrew/cask/grate.rb')
)

$ErrorActionPreference = 'Stop'
if ($releaseTag -cne $version -and $releaseTag -cne "v$version") {
    throw 'releaseTag must be the version or the version prefixed with v.'
}
$armArchive = Join-Path $artifactDirectory "grate-osx-arm64-self-contained-$version.zip"
$intelArchive = Join-Path $artifactDirectory "grate-osx-x64-self-contained-$version.zip"
$armHash = (Get-FileHash -LiteralPath $armArchive -Algorithm SHA256).Hash.ToLowerInvariant()
$intelHash = (Get-FileHash -LiteralPath $intelArchive -Algorithm SHA256).Hash.ToLowerInvariant()
$outputPath = [System.IO.Path]::GetFullPath($outputPath)
$null = New-Item -ItemType Directory -Path ([System.IO.Path]::GetDirectoryName($outputPath)) -Force

# Use the final release archives; never guess checksums before they exist.
@"
cask "grate" do
  version "$version"
  name "grate"
  desc "grate - the SQL scripts migration runner"
  homepage "https://grate-devs.github.io/grate/"

  if Hardware::CPU.arm?
    url "https://github.com/grate-devs/grate/releases/download/$releaseTag/grate-osx-arm64-self-contained-#{version}.zip"
    sha256 "$armHash"
  end
  if Hardware::CPU.intel?
    url "https://github.com/grate-devs/grate/releases/download/$releaseTag/grate-osx-x64-self-contained-#{version}.zip"
    sha256 "$intelHash"
  end

  depends_on :macos

  binary "grate"
end
"@ | Set-Content -LiteralPath $outputPath
