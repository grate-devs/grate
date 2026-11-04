#!/usr/bin/env pwsh
param (
    [Parameter(Mandatory=$true)] [string]$RequestPath,
    [Parameter(Mandatory=$true)] [string]$OutputPath
)
$ErrorActionPreference = 'Stop'
if (!$IsWindows) { throw 'Native MSI inventory batch inspection requires Windows.' }
# The waiting lifecycle process never loads MSI.dll, including through native
# APIs. Every inventory generation is gathered in this short-lived worker.
$rows = foreach ($code in @(Get-Content -LiteralPath $RequestPath -Raw | ConvertFrom-Json)) {
    @{ Phase = 'ProductInventoryStart'; ProductCode = $code; Utc = [DateTime]::UtcNow.ToString('o') } |
        ConvertTo-Json -Compress | Add-Content -LiteralPath ($OutputPath + '.progress.log')
    $inventory = & (Join-Path $PSScriptRoot 'Get-InstalledProductInventory.ps1') -ProductCode $code
    @{ Phase = 'ProductInventoryEnd'; ProductCode = $code; Utc = [DateTime]::UtcNow.ToString('o') } |
        ConvertTo-Json -Compress | Add-Content -LiteralPath ($OutputPath + '.progress.log')
    [pscustomobject]@{ ProductCode = $code; Inventory = $inventory }
}
@($rows) | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $OutputPath
