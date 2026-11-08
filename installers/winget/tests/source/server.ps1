#!/usr/bin/env pwsh
param(
    [Parameter(Mandatory)][string]$Catalog,
    [Parameter(Mandatory)][string]$Certificate,
    [Parameter(Mandatory)][string]$PrivateKey,
    [string]$Assets,
    [ValidateRange(0,65535)][int]$Port = 8765
)
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot/SourceServer.ps1"
$catalogPath = (Resolve-Path -LiteralPath $Catalog).Path
$settings = @{Catalog=$catalogPath;SourceIdentifier=(Read-SourceCatalog $catalogPath).SourceIdentifier;Assets=$Assets;Preindexed=$false}
Start-SourceServer $settings $Certificate $PrivateKey $Port
