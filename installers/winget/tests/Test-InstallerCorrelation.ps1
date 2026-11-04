#!/usr/bin/env pwsh
# Checks wingetcreate's block-style installer YAML against independently read
# MSI metadata. This is deliberately bounded to its emitted format, not a YAML parser.
param (
    [Parameter(Mandatory)] [string]$ManifestPath,
    [Parameter(Mandatory)] [string]$InstallerUrl,
    [Parameter(Mandatory)] [ValidateSet('x64', 'arm64')] [string]$Architecture,
    [Parameter(Mandatory)] [string]$ProductCode,
    [Parameter(Mandatory)] [string]$UpgradeCode,
    [Parameter(Mandatory)] [string]$Sha256,
    [ValidateSet('Historical', 'Bridge', 'NewIdentity')] [string]$Policy = 'Historical',
    [string]$Publisher
)
$ErrorActionPreference = 'Stop'
$yaml = Get-Content -LiteralPath $ManifestPath -Raw
$nodes = @([regex]::Split($yaml, '(?m)(?=^- )') | Where-Object {
    $_ -match "(?m)^  InstallerUrl: $([regex]::Escape($InstallerUrl))\r?$"
})
if ($nodes.Count -ne 1) { throw 'Expected exactly one installer node for the inspected MSI URL.' }
foreach ($field in @{
    Architecture = $Architecture; InstallerSha256 = $Sha256
}.GetEnumerator()) {
    # Architecture can be the first property in a node; codes can appear at
    # installer level or in AppsAndFeaturesEntries. Never match another node.
    $pattern = "(?m)^(?:- | +(?:- )?)$($field.Key): ['`"]?$([regex]::Escape($field.Value))['`"]?\r?$"
    if ($nodes[0] -cnotmatch $pattern) { throw "MSI installer node has incorrect $($field.Key)." }
}
if ($Policy -eq 'Bridge') {
    if ($yaml -match '(?m)^\s*(?:- )?(?:ProductCode|UpgradeCode):') { throw 'Bridge manifests must not contain strong MSI reference codes.' }
    $Publisher = 'erikbra'
} else {
    foreach ($field in @{ProductCode=$ProductCode; UpgradeCode=$UpgradeCode}.GetEnumerator()) {
        $pattern = "(?m)^(?:- | +(?:- )?)$($field.Key): ['`"]?$([regex]::Escape($field.Value))['`"]?\r?$"
        if ($nodes[0] -cnotmatch $pattern) { throw "MSI installer node has incorrect $($field.Key)." }
    }
}
if ($Policy -ne 'Historical') {
    # MSI Scope is omitted for pinned-client correlation (#3011). Portable
    # Scope is unsupported manifest authoring; settings/--scope select it.
    if ($yaml -match '(?m)^(?:  )?Scope:') { throw 'Migration installer Scope must be omitted.' }
    if ($Policy -eq 'NewIdentity') {
        if (!$Publisher) { $Publisher = 'grate-devs' }
        $productPattern = "(?m)^  ProductCode: ['`"]?$([regex]::Escape($ProductCode))['`"]?\r?$"
        $entryPattern = "(?m)^    ProductCode: ['`"]?$([regex]::Escape($ProductCode))['`"]?\r?$"
        if ($nodes[0] -cnotmatch $productPattern -or $nodes[0] -cnotmatch $entryPattern) { throw 'New MSI ProductCode must appear at installer and AppsAndFeaturesEntries levels.' }
    }
}
if ($Publisher) {
    $publisherPattern = "(?m)^  (?:- |  )Publisher: ['`"]?$([regex]::Escape($Publisher))['`"]?\r?$"
    if ($nodes[0] -cnotmatch $publisherPattern) { throw 'MSI AppsAndFeaturesEntries has incorrect Publisher.' }
}
