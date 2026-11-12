#!/usr/bin/env pwsh
param (
    [Parameter(Mandatory=$true)] [string]$RequestPath,
    [Parameter(Mandatory=$true)] [string]$OutputPath
)
$ErrorActionPreference = 'Stop'
if (!$IsWindows) { throw 'MSI metadata batch inspection requires Windows.' }
# Keep Windows Installer COM and its apartment entirely in this read-only worker
# process. The process that waits on msiexec never activates this COM server.
$rows = foreach ($path in @(Get-Content -LiteralPath $RequestPath -Raw | ConvertFrom-Json)) {
    $resolved = (Resolve-Path -LiteralPath $path).Path
    [pscustomobject]@{ Path = $resolved; Metadata = (& (Join-Path $PSScriptRoot 'Get-InstallerMetadata.ps1') -MsiPath $resolved) }
}
@($rows) | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $OutputPath
