#!/usr/bin/env pwsh
param(
    [Parameter(Mandatory)]
    [string]$Directory,
    [Parameter(Mandatory)]
    [string]$Version,
    [Parameter(Mandatory)]
    [AllowEmptyString()]
    [string]$Tag,
    [Parameter(Mandatory)]
    [string]$Repository
)

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot/distribution_profiles.ps1"
Write-GrateReleaseManifest -Directory $Directory -Version $Version -Tag $Tag -Repository $Repository
