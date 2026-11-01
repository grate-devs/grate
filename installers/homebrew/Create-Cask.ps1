#!/usr/bin/env pwsh

param (
    [Parameter(Mandatory=$true)] [string]$version,
    [Parameter(Mandatory=$true)] [string]$artifactDirectory,
    [string]$releaseTag = $version,
    [string]$outputPath = (Join-Path $PSScriptRoot 'grate.rb')
)

$ErrorActionPreference = 'Stop'
$armArchive = Join-Path $artifactDirectory "grate-osx-arm64-self-contained-$version.zip"
$intelArchive = Join-Path $artifactDirectory "grate-osx-x64-self-contained-$version.zip"
$armHash = (Get-FileHash -LiteralPath $armArchive -Algorithm SHA256).Hash.ToLowerInvariant()
$intelHash = (Get-FileHash -LiteralPath $intelArchive -Algorithm SHA256).Hash.ToLowerInvariant()

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

  binary "grate"
end
"@ | Set-Content -LiteralPath $outputPath
