#!/usr/bin/env pwsh
param (
    [Parameter(Mandatory)] [string]$InventoryDirectory
)

$ErrorActionPreference = 'Stop'
# This is a planning union of existing graphs, not a restore of an implemented profile.
foreach ($rid in @('linux-arm64', 'linux-x64')) {
    $union = [Collections.Generic.SortedDictionary[string, object]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($profile in @('MariaDB', 'SQLite', 'SQLServer', 'PostgreSQL-library')) {
        $relative = "inventory/$profile-net11.0-$rid/dependency-matrix.json"
        $rows = Get-Content -LiteralPath (Join-Path $InventoryDirectory $relative) -Raw | ConvertFrom-Json
        foreach ($row in $rows) {
            $key = "$($row.id)/$($row.version)"
            if (!$union.ContainsKey($key)) {
                $union[$key] = [ordered]@{
                    id = $row.id
                    version = $row.version
                    license = $row.license
                    repository = $row.repository
                    repositoryCommit = $row.repositoryCommit
                    matrixReference = $relative
                    sourceProfiles = @()
                }
            }
            $union[$key].sourceProfiles += $profile
        }
    }
    [ordered]@{
        profile = 'Prospective-AllExceptOracle'
        rid = $rid
        inference = 'Union of existing non-Oracle graphs; no compiled CLI profile or resolved combined graph exists.'
        packages = @($union.Values)
    } | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $InventoryDirectory "prospective-all-except-oracle-$rid.json") -Encoding utf8NoBOM
}
