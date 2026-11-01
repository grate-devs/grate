#!/usr/bin/env pwsh
# Checks wingetcreate's block-style installer YAML against independently read
# MSI metadata. This is deliberately bounded to its emitted format, not a YAML parser.
param (
    [Parameter(Mandatory)] [string]$ManifestPath,
    [Parameter(Mandatory)] [string]$InstallerUrl,
    [Parameter(Mandatory)] [ValidateSet('x64', 'arm64')] [string]$Architecture,
    [Parameter(Mandatory)] [string]$ProductCode,
    [Parameter(Mandatory)] [string]$UpgradeCode,
    [Parameter(Mandatory)] [string]$Sha256
)
$ErrorActionPreference = 'Stop'
$yaml = Get-Content -LiteralPath $ManifestPath -Raw
$nodes = @([regex]::Split($yaml, '(?m)(?=^- )') | Where-Object {
    $_ -match "(?m)^  InstallerUrl: $([regex]::Escape($InstallerUrl))\r?$"
})
if ($nodes.Count -ne 1) { throw 'Expected exactly one installer node for the inspected MSI URL.' }
foreach ($field in @{
    Architecture = $Architecture; ProductCode = $ProductCode; UpgradeCode = $UpgradeCode; InstallerSha256 = $Sha256
}.GetEnumerator()) {
    # Architecture can be the first property in a node; codes can appear at
    # installer level or in AppsAndFeaturesEntries. Never match another node.
    $pattern = "(?m)^(?:- | +(?:- )?)$($field.Key): ['`"]?$([regex]::Escape($field.Value))['`"]?\r?$"
    if ($nodes[0] -cnotmatch $pattern) { throw "MSI installer node has incorrect $($field.Key)." }
}
