# Bounded transformations for wingetcreate's block-style installer YAML. This is
# not a general YAML parser: reject another shape instead of guessing inheritance.
# Keep this pure policy callable for unreleased CI candidates as well as releases.
Set-StrictMode -Version Latest

function Get-WinGetScalar([string]$Text, [string]$Name, [switch]$Root, [switch]$Required) {
    $prefix = if ($Root) { '' } else { '(?:- |  )' }
    $found = [regex]::Matches($Text, "(?m)^$prefix$([regex]::Escape($Name)): (?<value>[^\r\n]+)\r?$")
    if ($found.Count -gt 1 -or ($Required -and $found.Count -ne 1)) { throw "Expected one block-style $Name scalar." }
    if ($found.Count -eq 0) { return $null }
    $value = $found[0].Groups['value'].Value.Trim()
    if ($value -match "^(['`"])(.*)\1$") { return $Matches[2] }
    return $value
}

function Get-WinGetInstallerDocument([string]$Text) {
    $document = [regex]::Match($Text, '(?ms)\A(?<header>.*?)^Installers:\r?\n(?<body>.*?)(?<footer>^ManifestType: installer\r?\n.*)\z')
    if (!$document.Success) { throw 'Expected wingetcreate block-style Installers and ManifestType fields.' }
    $nodes = @([regex]::Split($document.Groups['body'].Value, '(?m)(?=^- )') | Where-Object { $_.Trim() })
    if ($nodes.Count -eq 0 -or @($nodes | Where-Object { $_ -notmatch '\A- [A-Za-z]' }).Count) {
        throw 'Expected block-style installer nodes without YAML aliases.'
    }
    [pscustomobject]@{ Header=$document.Groups['header'].Value; Nodes=$nodes; Footer=$document.Groups['footer'].Value }
}

function Remove-WinGetInstallerField([string]$Text, [string]$Name, [switch]$Root) {
    $prefix = if ($Root) { '' } else { '  ' }
    # A removed field must not be the first item key, as that would orphan the
    # node. wingetcreate starts nodes with Architecture or InstallerLocale.
    if (!$Root -and $Text -match "(?m)^- $([regex]::Escape($Name)):") { throw "Unsupported first installer field: $Name" }
    [regex]::Replace($Text, "(?m)^$prefix$([regex]::Escape($Name)): [^\r\n]*\r?\n", '')
}

function Remove-WinGetAppsAndFeatures([string]$Text, [switch]$Root) {
    $prefix = if ($Root) { '' } else { '  ' }
    if ($Text -match "(?m)^$prefix" + 'AppsAndFeaturesEntries: [^\r\n]+') {
        throw 'Expected block-style AppsAndFeaturesEntries.'
    }
    $stop = if ($Root) { '(?=^[A-Za-z]|\z)' } else { '(?=^  [A-Za-z]|\z)' }
    [regex]::Replace($Text, "(?ms)^${prefix}AppsAndFeaturesEntries:\r?\n.*?$stop", '')
}

function Assert-WinGetMigrationMetadata([object[]]$MsiMetadata, [string]$Version, [string]$IdentityContractPath) {
    $contract = Get-Content -LiteralPath $IdentityContractPath -Raw | ConvertFrom-Json
    if ($contract.SchemaVersion -ne 1 -or $contract.Manufacturer -cne 'grate-devs') { throw 'Unsupported MSI identity contract.' }
    $products = @()
    if ($MsiMetadata.Count -lt 1 -or $MsiMetadata.Count -gt 2) { throw 'Migration requires one or two independently inspected MSI products.' }
    foreach ($architecture in @($MsiMetadata.Architecture | Select-Object -Unique)) {
        if ($architecture -cnotin @('x64', 'arm64')) { throw 'Unsupported migration MSI architecture.' }
        $items = @($MsiMetadata | Where-Object Architecture -CEQ $architecture)
        if ($items.Count -ne 1) { throw "Expected independently inspected $architecture MSI metadata." }
        $item = $items[0]
        if ($item.Manufacturer -cne $contract.Manufacturer -or $item.ProductName -cne $contract.ProductName -or
            $item.ProductVersion -cne $Version -or $item.Platform -cne $architecture) {
            throw "Migration requires the corrected $architecture MSI with actual grate-devs publisher, version and platform."
        }
        # Omitting Scope in WinGet YAML works around client correlation behavior;
        # it must not conceal an actual change in the MSI installation context.
        if (![string]::IsNullOrEmpty([string]$item.AllUsers) -or
            ![string]::IsNullOrEmpty([string]$item.MsiInstallPerUser)) {
            throw 'Migration requires per-user-only MSI authoring with empty ALLUSERS and MSIINSTALLPERUSER.'
        }
        $parsed = [guid]::Empty
        if (![guid]::TryParse($item.ProductCode, [ref]$parsed) -or $parsed -eq [guid]::Empty -or
            $item.ProductCode -ieq $contract.LegacyProductCode) {
            throw 'Migration requires new MSI ProductCodes; the legacy fixed ProductCode must not alias the new identity.'
        }
        if ($item.UpgradeCode -ine $contract.Architectures.$architecture.UpgradeCode) { throw "Migration requires the stable $architecture MSI UpgradeCode from the identity contract." }
        $identity = & (Join-Path (Split-Path $PSScriptRoot) 'msi/Get-InstallerIdentity.ps1') -Version $Version -Architecture $architecture
        if ($item.ProductCode -ine $identity.ProductCode) { throw "Migration requires the version-specific $architecture MSI ProductCode from the identity contract." }
        if ($item.Sha256 -notmatch '^[A-Fa-f0-9]{64}$') { throw 'Migration requires an independently computed MSI SHA256.' }
        $products += $item.ProductCode.ToUpperInvariant()
    }
    if (@($products | Select-Object -Unique).Count -ne $MsiMetadata.Count) {
        throw 'Migration requires distinct architecture-specific MSI products.'
    }
}

function ConvertTo-WinGetMigrationManifests {
    param (
        [Parameter(Mandatory)] [string]$InstallerYaml,
        [Parameter(Mandatory)] [string]$Version,
        [Parameter(Mandatory)] [object[]]$MsiMetadata,
        [string]$IdentityContractPath = (Join-Path (Split-Path $PSScriptRoot) 'msi/identity-contract.json')
    )
    Assert-WinGetMigrationMetadata $MsiMetadata $Version $IdentityContractPath
    $document = Get-WinGetInstallerDocument $InstallerYaml
    if ((Get-WinGetScalar $document.Header PackageIdentifier -Root -Required) -cne 'erikbra.grate' -or
        (Get-WinGetScalar $document.Header PackageVersion -Root -Required) -cne $Version) {
        throw 'Unexpected package identity/version in migration installer manifest.'
    }
    $header = $document.Header
    foreach ($field in @('Scope', 'ProductCode', 'UpgradeCode')) { $header = Remove-WinGetInstallerField $header $field -Root }
    $header = Remove-WinGetAppsAndFeatures $header -Root
    $bridgeNodes = @(); $newNodes = @(); $seenUrls = @()
    foreach ($node in $document.Nodes) {
        $url = Get-WinGetScalar $node InstallerUrl -Required
        if ($url -in $seenUrls) { throw 'Duplicate migration installer URL.' }
        $seenUrls += $url
        $architecture = Get-WinGetScalar $node Architecture -Required
        $type = Get-WinGetScalar $node InstallerType
        if (!$type) { $type = Get-WinGetScalar $document.Header InstallerType -Root -Required }
        $clean = Remove-WinGetInstallerField $node Scope
        if ($type -eq 'zip') {
            $nestedType = Get-WinGetScalar $node NestedInstallerType
            if (!$nestedType) { $nestedType = Get-WinGetScalar $document.Header NestedInstallerType -Root -Required }
            if ($nestedType -ne 'portable') { throw 'Expected ZIP portable installers in migration manifests.' }
            # Portable scope is selected by WinGet settings/--scope, not by the
            # manifest. Emitting it produces a validation warning and nonzero exit.
            $clean = $clean.TrimEnd() + "`n"
            $bridgeNodes += $clean; $newNodes += $clean
            continue
        }
        if ($type -notin @('wix', 'msi')) { throw "Unexpected migration installer type: $type" }
        $items = @($MsiMetadata | Where-Object { $_.Architecture -ceq $architecture -and $_.InstallerUrl -ceq $url })
        if ($items.Count -ne 1) { throw 'MSI node does not match independently inspected URL and architecture.' }
        $metadata = $items[0]
        if ((Get-WinGetScalar $node InstallerSha256 -Required) -ine $metadata.Sha256) { throw 'MSI node has incorrect InstallerSha256.' }
        $clean = Remove-WinGetInstallerField $clean ProductCode
        $clean = Remove-WinGetInstallerField $clean UpgradeCode
        $clean = Remove-WinGetAppsAndFeatures $clean
        $clean = $clean.TrimEnd() + "`n"
        # Retain the old-publisher bridge only for diagnostic regression tests.
        # Actual installs enrich old-ID tracking even when these codes are absent;
        # production preparation must emit only NewInstallerYaml.
        $bridgeNodes += $clean + "  AppsAndFeaturesEntries:`n  - DisplayName: grate`n    Publisher: erikbra`n"
        $newNodes += $clean + "  ProductCode: '$($metadata.ProductCode)'`n  AppsAndFeaturesEntries:`n  - DisplayName: grate`n    Publisher: grate-devs`n    ProductCode: '$($metadata.ProductCode)'`n    UpgradeCode: '$($metadata.UpgradeCode)'`n"
    }
    foreach ($metadata in $MsiMetadata) {
        if ($metadata.InstallerUrl -cnotin $seenUrls) { throw 'An inspected MSI is missing from the migration manifest.' }
    }
    $bridge = $header + "Installers:`n" + ($bridgeNodes -join '') + $document.Footer
    $new = ($header -creplace '(?m)^PackageIdentifier: erikbra\.grate\r?$', 'PackageIdentifier: grate-devs.grate') + "Installers:`n" + ($newNodes -join '') + $document.Footer
    if ($bridge -match '(?m)^\s*(?:- )?(?:ProductCode|UpgradeCode):') { throw 'Bridge manifests must not contain strong MSI reference codes.' }
    [pscustomobject]@{ BridgeInstallerYaml=$bridge; NewInstallerYaml=$new }
}
