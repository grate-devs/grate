#!/usr/bin/env pwsh
[CmdletBinding()]
param(
    [ValidateSet('full', 'pr-preview')]
    [string] $Tier = 'full',
    [string] $EventName,
    [string] $Ref
)

$ErrorActionPreference = 'Stop'
$catalog = Join-Path $PSScriptRoot '../../.github/compatibility-databases.json'
$databases = @(Get-Content -LiteralPath $catalog -Raw | ConvertFrom-Json)
if ($databases.Count -eq 0 -or @($databases.name | Sort-Object -Unique).Count -ne $databases.Count) {
    throw 'The compatibility catalog must contain unique database names.'
}

if ($Tier -eq 'full') {
    return $databases
}

# This measures a possible PR tier without granting ordinary PRs or release
# evidence consumers the ability to omit historical versions.
$pilotRefs = @(
    'refs/heads/ci/942-compatibility-pr957'
    'refs/heads/ci/942-compatibility-pr894'
)
if ($EventName -cne 'workflow_dispatch' -or $Ref -cnotin $pilotRefs) {
    throw 'The reduced matrix is only available for manual measurement on the two pilot branches.'
}

$previewNames = @(
    'SqlServer 2025'
    'SqlServer case-sensitive 2022'
    'PostgreSQL 18'
    'MariaDB 12'
    'Sqlite'
    'Oracle Free latest'
)
$preview = @($databases | Where-Object { $_.name -cin $previewNames })
if ($preview.Count -ne $previewNames.Count) {
    throw 'The preview matrix is missing an expected database configuration.'
}
return $preview
