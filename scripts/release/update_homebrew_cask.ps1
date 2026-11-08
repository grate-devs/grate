#!/usr/bin/env pwsh
[CmdletBinding()]
param([string]$Version, [string]$Arm64Sha256, [string]$X64Sha256, [string]$Output)
$ErrorActionPreference = 'Stop'
function Write-HomebrewCask([string]$Version, [string]$Arm64Sha256, [string]$X64Sha256, [string]$Output) {
    if ($Version -cnotmatch '\A[0-9]+\.[0-9]+\.[0-9]+\z') { throw 'Homebrew only publishes stable SemVer versions.' }
    $Arm64Sha256 = $Arm64Sha256.ToLowerInvariant()
    $X64Sha256 = $X64Sha256.ToLowerInvariant()
    if ($Arm64Sha256 -cnotmatch '\A[0-9a-f]{64}\z' -or $X64Sha256 -cnotmatch '\A[0-9a-f]{64}\z') { throw 'Invalid SHA-256.' }
    $content = @"
cask "grate" do
  arch arm: "arm64", intel: "x64"

  version "$Version"
  sha256 arm:   "$Arm64Sha256",
         intel: "$X64Sha256"

  url "https://github.com/grate-devs/grate/releases/download/#{version}/grate-osx-#{arch}-self-contained-#{version}.zip"
  name "grate"
  desc "SQL scripts migration runner"
  homepage "https://grate-devs.github.io/grate/"

  binary "grate"
end
"@
    $path = [IO.Path]::GetFullPath($Output)
    $null = [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($path))
    [IO.File]::WriteAllText($path, $content + "`n", [Text.UTF8Encoding]::new($false))
}
if ($MyInvocation.InvocationName -ne '.') { Write-HomebrewCask $Version $Arm64Sha256 $X64Sha256 $Output }
