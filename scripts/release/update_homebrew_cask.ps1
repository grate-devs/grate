#!/usr/bin/env pwsh
[CmdletBinding()]
param(
    [string]$Version,
    [string]$Arm64Sha256,
    [string]$X64Sha256,
    [string]$Output,
    [ValidateSet('All', 'SQLite', 'SQLServer', 'MariaDB', 'PostgreSQL', 'Oracle')]
    [string]$Distribution = 'All',
    [switch]$AllDistributions,
    [string]$ArtifactDirectory,
    [string]$OutputDirectory,
    [string]$ReleaseTag = $Version
)

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot/../../installers/homebrew/Homebrew.Common.ps1"
if ($MyInvocation.InvocationName -ne '.') {
    if ($AllDistributions) {
        if ($Distribution -ne 'All' -or $Output -or $Arm64Sha256 -or $X64Sha256 -or !$ArtifactDirectory -or !$OutputDirectory) {
            throw 'AllDistributions requires ArtifactDirectory and OutputDirectory instead of per-cask hashes/output.'
        }
        $parameters = @{
            version = $Version
            releaseTag = $ReleaseTag
            artifactDirectory = $ArtifactDirectory
            OutputDirectory = $OutputDirectory
            AllDistributions = $true
        }
        & "$PSScriptRoot/../../installers/homebrew/Create-Cask.ps1" @parameters
    } else {
        $parameters = @{
            Version = $Version
            ReleaseTag = $ReleaseTag
            Arm64Sha256 = $Arm64Sha256
            X64Sha256 = $X64Sha256
            Output = $Output
            Distribution = $Distribution
        }
        Write-HomebrewCask @parameters
    }
}
