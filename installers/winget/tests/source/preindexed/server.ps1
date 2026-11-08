#!/usr/bin/env pwsh
param(
    [Parameter(Mandatory)][string]$Root,
    [Parameter(Mandatory)][string]$Assets,
    [Parameter(Mandatory)][string]$Certificate,
    [Parameter(Mandatory)][string]$PrivateKey,
    [ValidateRange(0,65535)][int]$Port = 8765
)
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot/../SourceServer.ps1"
$settings = @{Root=(Resolve-Path -LiteralPath $Root).Path;Assets=(Resolve-Path -LiteralPath $Assets).Path;Preindexed=$true}
Start-SourceServer $settings $Certificate $PrivateKey $Port
