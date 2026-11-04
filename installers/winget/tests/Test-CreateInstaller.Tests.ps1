#!/usr/bin/env pwsh
# Release preparation contract: recording tools and independent MSI metadata.
# Windows/schema and actual install/upgrade checks remain separate.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$previousNativeExitCode = Get-Variable -Name LASTEXITCODE -Scope Global -ErrorAction SilentlyContinue
$previousNativeExitCodeValue = if ($previousNativeExitCode) { $previousNativeExitCode.Value } else { $null }
$helper = Join-Path $PSScriptRoot '../Create-Installer.ps1'
. (Join-Path $PSScriptRoot '../helpers/MigrationManifestPolicy.ps1')
$state = Join-Path ([IO.Path]::GetTempPath()) ('grate-winget-tests-' + [Guid]::NewGuid().ToString('N'))
$wingetTest = @{ apiCalls=0; toolCalls=0; downloadCalls=0; metadataCalls=0; schemaCalls=0; schemaExitCode=0; toolExitCode=0; wrongOutput=$false; arguments=@(); testCount=0; release=$null; metadata=@{} }
function Test-Hash([string]$Architecture) {
    [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes("payload-$Architecture")))
}
function Set-Release([string]$Version='2.1.7', [switch]$Corrected) {
    $wingetTest.release = [pscustomobject]@{
        tag_name=$Version; draft=$false; prerelease=$false; published_at='2026-07-31T21:00:00Z'
        assets=@("grate-win-x86-self-contained-$Version.zip", "grate-win-x64-self-contained-$Version.zip", "grate-win-arm64-self-contained-$Version.zip", "grate-msi-win-x64-$Version.msi", "grate-msi-win-arm64-$Version.msi") | ForEach-Object {
            $arch = if ($_ -like '*arm64*') {'arm64'} else {'x64'}
            [pscustomobject]@{name=$_; browser_download_url="https://github.com/grate-devs/grate/releases/download/$Version/$_"; state='uploaded'; size=123; digest=('sha256:'+(Test-Hash $arch).ToLowerInvariant())}
        }
    }
    foreach ($arch in @('x64','arm64')) {
        $identity = & "$PSScriptRoot/../../msi/helpers/Get-InstallerIdentity.ps1" -Version $Version -Architecture $arch
        $wingetTest.metadata[$arch] = [pscustomobject]@{
            ProductCode=$(if ($Corrected) {$identity.ProductCode} else {'{E281998A-D8A2-4926-AAA3-066EFA4B2E74}'})
            UpgradeCode=$(if ($Corrected) {$identity.UpgradeCode} else {'{98CF60F4-3F43-4ACE-B364-ADBCD893A144}'})
            Manufacturer=$(if ($Corrected) {'grate-devs'} else {'erikbra'})
            ProductName='grate'; ProductVersion=$Version; Platform=$arch
            AllUsers=$null; MsiInstallPerUser=''
        }
    }
}
function Invoke-RestMethod([string]$Uri, [hashtable]$Headers) {
    $wingetTest.apiCalls++
    if ($Uri -cne "https://api.github.com/repos/grate-devs/grate/releases/tags/$($wingetTest.release.tag_name)") { throw "Unexpected API call: $Uri" }
    $wingetTest.release
}
function Invoke-WebRequest([string]$Uri, [string]$OutFile) {
    $wingetTest.downloadCalls++
    $arch = if ($Uri -like '*arm64*') {'arm64'} else {'x64'}
    [IO.File]::WriteAllText($OutFile, "payload-$arch")
}
function Read-TestMsiMetadata([string]$MsiPath) {
    $wingetTest.metadataCalls++
    $arch = if ($MsiPath -like '*arm64*') {'arm64'} else {'x64'}
    $wingetTest.metadata[$arch]
}
function Invoke-TestWingetCreate {
    $wingetTest.toolCalls++
    $wingetTest.arguments = @($args | ForEach-Object { $_ })
    $global:LASTEXITCODE = $wingetTest.toolExitCode
    if ($wingetTest.toolExitCode -ne 0) { return }
    $version = $args[($args.IndexOf('-v')+1)]
    $path = Join-Path $args[($args.IndexOf('-o')+1)] "manifests/e/erikbra/grate/$version"
    New-Item -ItemType Directory -Path $path -Force | Out-Null
    $writtenVersion = if ($wingetTest.wrongOutput) {'0.0.1'} else {$version}
    $common = "PackageIdentifier: erikbra.grate`nPackageVersion: $writtenVersion`n"
    ($common+"DefaultLocale: en-US`nManifestType: version`nManifestVersion: 1.12.0`n") | Set-Content (Join-Path $path 'erikbra.grate.yaml')
    ($common+"PackageLocale: en-US`nPublisher: erikbra`nPackageName: grate`nLicense: MIT`nShortDescription: SQL migrations`nManifestType: defaultLocale`nManifestVersion: 1.12.0`n") | Set-Content (Join-Path $path 'erikbra.grate.locale.en-US.yaml')
    $nodes = foreach ($arch in @('x86','x64','arm64')) {
        "- Architecture: $arch`n  InstallerType: zip`n  NestedInstallerType: portable`n  NestedInstallerFiles:`n  - RelativeFilePath: grate.exe`n  InstallerUrl: https://github.com/grate-devs/grate/releases/download/$version/grate-win-$arch-self-contained-$version.zip`n  InstallerSha256: $('A'*64)`n"
    }
    foreach ($arch in @('x64','arm64')) {
        # Stale upstream AFE values must be replaced using actual inspected MSI
        # metadata, never mistaken for evidence that the payload was corrected.
        $nodes += "- InstallerLocale: en-US`n  Architecture: $arch`n  InstallerType: wix`n  Scope: user`n  InstallerUrl: https://github.com/grate-devs/grate/releases/download/$version/grate-msi-win-$arch-$version.msi`n  InstallerSha256: $(Test-Hash $arch)`n  ProductCode: '{E281998A-D8A2-4926-AAA3-066EFA4B2E74}'`n  AppsAndFeaturesEntries:`n  - Publisher: erikbra`n    UpgradeCode: '{98CF60F4-3F43-4ACE-B364-ADBCD893A144}'`n"
    }
    ($common+"Scope: user`nProductCode: '{E281998A-D8A2-4926-AAA3-066EFA4B2E74}'`nUpgradeCode: '{98CF60F4-3F43-4ACE-B364-ADBCD893A144}'`nInstallers:`n"+($nodes -join '')+"ManifestType: installer`nManifestVersion: 1.12.0`n") | Set-Content (Join-Path $path 'erikbra.grate.installer.yaml')
}
function Read-TestCandidateMetadata([string]$MsiPath) {
    if ($MsiPath -notmatch 'candidate-(?<version>2\.1\.[78])\.msi$') { throw 'Unexpected candidate MSI fixture path.' }
    $identity=& "$PSScriptRoot/../../msi/helpers/Get-InstallerIdentity.ps1" -Version $Matches.version -Architecture x64
    [pscustomobject]@{ProductCode=$identity.ProductCode; UpgradeCode=$identity.UpgradeCode; Manufacturer=$identity.Manufacturer; ProductName=$identity.ProductName; ProductVersion=$identity.Version; Platform='x64'; AllUsers=''; MsiInstallPerUser=$null}
}
function Invoke-TestWingetValidate {
    if ($args[0] -ne 'validate' -or $args[1] -ne '--manifest' -or !(Test-Path $args[2])) { throw 'Schema command was not forwarded with its manifest directory.' }
    if ('--ignore-warnings' -in $args) { throw 'Candidate schema validation must not suppress warnings.' }
    foreach ($file in Get-ChildItem -LiteralPath $args[2] -Filter *.yaml) {
        $text = Get-Content -LiteralPath $file.FullName -Raw
        if ($text -notmatch '(?m)^ManifestType: (?<type>installer|defaultLocale|version)\r?$') { throw 'Missing candidate manifest type.' }
        $type=$Matches.type
        $expectedHeader='# yaml-language-server: $schema=https://aka.ms/winget-manifest.' + $type + '.1.12.0.schema.json'
        if ($text.Split("`n")[0].TrimEnd("`r") -cne $expectedHeader) { throw 'Missing or incorrect candidate schema header.' }
        if ($type -eq 'installer' -and $text -match '(?m)^\s*(?:- )?Scope:') { throw 'Candidate manifests must omit unsupported portable/MSI Scope.' }
    }
    $wingetTest.schemaCalls++
    $global:LASTEXITCODE=$wingetTest.schemaExitCode
    if ($wingetTest.schemaExitCode) { Write-Output 'Manifest validation succeeded with warnings.' }
}
function Assert-True([bool]$Condition, [string]$Message) { if (!$Condition) { throw $Message } }
function Prepare([string]$Directory, [switch]$Migration) {
    & $helper -version $wingetTest.release.tag_name -wingetCreate Invoke-TestWingetCreate -MsiMetadataReader Read-TestMsiMetadata -outputDirectory $Directory -PrepareMigration:$Migration
}
function Assert-Rejected([hashtable]$Parameters, [string]$Message, [switch]$AllowToolCall) {
    $before = $wingetTest.toolCalls
    if (!$Parameters.ContainsKey('outputDirectory')) { $Parameters.outputDirectory=Join-Path $state ([guid]::NewGuid().ToString('N')) }
    try { & $helper @Parameters -wingetCreate Invoke-TestWingetCreate -MsiMetadataReader Read-TestMsiMetadata }
    catch {
        if ($_.Exception.Message -notlike $Message) { throw }
        if (!$AllowToolCall) { Assert-True ($wingetTest.toolCalls -eq $before) 'Rejected input still invoked wingetcreate.' }
        $wingetTest.testCount++
        return
    }
    throw "Expected rejection: $Message"
}
try {
    Set-Release -Version 2.1.6
    Prepare "$state/update"
    $expectedUrls = @('win-x86-self-contained-2.1.6.zip|x86','win-x64-self-contained-2.1.6.zip|x64','win-arm64-self-contained-2.1.6.zip|arm64','msi-win-x64-2.1.6.msi|x64','msi-win-arm64-2.1.6.msi|arm64') | ForEach-Object {"https://github.com/grate-devs/grate/releases/download/2.1.6/grate-$_"}
    Assert-True ($wingetTest.arguments[0] -eq 'update' -and $wingetTest.arguments[1] -eq 'erikbra.grate') 'Default must update the accepted identity.'
    Assert-True (($wingetTest.arguments[3..7] -join "`n") -ceq ($expectedUrls -join "`n")) 'Five asset URLs/architectures were not passed intact.'
    Assert-True ('-s' -notin $wingetTest.arguments -and '--submit' -notin $wingetTest.arguments) 'Preparation must not submit.'
    Assert-True ('https://github.com/grate-devs/grate/releases/tag/2.1.6' -in $wingetTest.arguments -and '2026-07-31' -in $wingetTest.arguments) 'Release metadata missing.'
    $historical = Get-Content "$state/update/manifests/e/erikbra/grate/2.1.6/erikbra.grate.installer.yaml" -Raw
    Assert-True ($historical.Contains('Scope: user') -and $historical.Contains("ProductCode: '{E281998A-D8A2-4926-AAA3-066EFA4B2E74}'") -and $wingetTest.metadataCalls -eq 2) 'Ordinary legacy metadata was changed or actual MSI inspection was omitted.'
    $wingetTest.testCount++
    Assert-Rejected @{version='2.1.6'; PrepareMigration=$true} '*corrected*MSI*actual grate-devs publisher*'

    Set-Release -Corrected
    # Even when upstream/wingetcreate still reports old AFE values, actual new
    # MSI identity must force the opt-in migration path before invoking the tool.
    Assert-Rejected @{version='2.1.7';outputDirectory="$state/default-corrected"} '*requires -PrepareMigration*'
    Assert-True (!(Test-Path "$state/default-corrected")) 'Default mode promoted corrected MSI identities under the old package ID.'
    Set-Release -Corrected
    $historicalDirectory = "$state/migration/manifests/e/erikbra/grate/2.1.6"
    New-Item -ItemType Directory -Path $historicalDirectory -Force | Out-Null
    $historical | Set-Content "$historicalDirectory/erikbra.grate.installer.yaml" -NoNewline
    Prepare "$state/migration" -Migration
    $old = "$state/migration/manifests/e/erikbra/grate/2.1.7"
    $new = "$state/migration/manifests/g/grate-devs/grate/2.1.7"
    Assert-True (!(Test-Path $old)) 'Migration preparation promoted a corrected MSI under the old ID.'
    Assert-True ((Get-Content "$historicalDirectory/erikbra.grate.installer.yaml" -Raw) -ceq $historical) 'Migration preparation changed historical old-ID metadata.'
    foreach ($item in @(@{Path=$new;Id='grate-devs.grate'})) {
        Assert-True (@(Get-ChildItem $item.Path).Count -eq 3) 'Each identity requires exactly three manifests.'
        foreach ($file in Get-ChildItem $item.Path) { Assert-True ((Get-Content $file.FullName -Raw).Contains("PackageIdentifier: $($item.Id)")) 'Package identity was not converted.' }
    }
    $candidate = Get-Content "$new/grate-devs.grate.installer.yaml" -Raw
    Assert-True ((Get-Content "$new/grate-devs.grate.locale.en-US.yaml" -Raw).Contains('Publisher: grate-devs')) 'New locale publisher missing.'
    # Preserve the rejected bridge design as a pure diagnostic regression, never
    # as a production output: absent codes cannot prevent tracking enrichment.
    $diagnosticMetadata = foreach ($arch in @('x64','arm64')) {
        $wingetTest.metadata[$arch] | Select-Object *, @{Name='Architecture';Expression={$arch}},
            @{Name='InstallerUrl';Expression={"https://github.com/grate-devs/grate/releases/download/2.1.7/grate-msi-win-$arch-2.1.7.msi"}},
            @{Name='Sha256';Expression={Test-Hash $arch}}
    }
    $diagnostic = ConvertTo-WinGetMigrationManifests -InstallerYaml ($candidate -creplace 'PackageIdentifier: grate-devs.grate', 'PackageIdentifier: erikbra.grate') -Version '2.1.7' -MsiMetadata @($diagnosticMetadata)
    Assert-True ($diagnostic.BridgeInstallerYaml -notmatch '(?m)^\s*(?:- )?(?:ProductCode|UpgradeCode):' -and $diagnostic.BridgeInstallerYaml.Contains('Publisher: erikbra')) 'Diagnostic bridge contract changed.'
    foreach ($arch in @('x64','arm64')) {
        $metadata=$wingetTest.metadata[$arch]
        $argsForValidator=@{InstallerUrl="https://github.com/grate-devs/grate/releases/download/2.1.7/grate-msi-win-$arch-2.1.7.msi";Architecture=$arch;ProductCode=$metadata.ProductCode;UpgradeCode=$metadata.UpgradeCode;Sha256=(Test-Hash $arch)}
        & "$PSScriptRoot/Test-InstallerCorrelation.ps1" @argsForValidator -ManifestPath "$new/grate-devs.grate.installer.yaml" -Policy NewIdentity -Publisher grate-devs
    }
    Assert-True ($candidate -notmatch '(?m)^\s*(?:- )?Scope:') 'Migration manifests must omit unsupported portable/MSI Scope.'
    Assert-True ([regex]::Matches($candidate,'(?m)^  NestedInstallerType: portable$').Count -eq 3) 'Portable ZIP installer shape was lost.'
    $wingetTest.testCount++
    Assert-Rejected @{version='2.1.7';outputDirectory="$state/migration";PrepareMigration=$true} '*Refusing to overwrite*'
    foreach ($defect in @('Publisher','LegacyProduct','WrongProduct','UpgradeCode','Platform','Version','Digest','MachineScope','DualScope','PerUserFlag','AllUsersZero')) {
        Set-Release -Corrected
        switch ($defect) {
            Publisher {$wingetTest.metadata.x64.Manufacturer='erikbra'}
            LegacyProduct {$wingetTest.metadata.x64.ProductCode='{E281998A-D8A2-4926-AAA3-066EFA4B2E74}'}
            WrongProduct {$wingetTest.metadata.x64.ProductCode='{11111111-1111-1111-1111-111111111111}'}
            UpgradeCode {$wingetTest.metadata.x64.UpgradeCode='{11111111-1111-1111-1111-111111111111}'}
            Platform {$wingetTest.metadata.arm64.Platform='x64'}
            Version {$wingetTest.metadata.arm64.ProductVersion='2.1.6'}
            Digest {$wingetTest.release.assets[3].digest='sha256:'+('0'*64)}
            # These fixtures retain the correct new identity. Scope must be
            # checked independently of ProductCode and Manufacturer.
            MachineScope {$wingetTest.metadata.x64.AllUsers='1'}
            DualScope {$wingetTest.metadata.arm64.AllUsers='2';$wingetTest.metadata.arm64.MsiInstallPerUser='1'}
            PerUserFlag {$wingetTest.metadata.x64.MsiInstallPerUser='1'}
            AllUsersZero {$wingetTest.metadata.x64.AllUsers='0'}
        }
        $expected=switch($defect) {LegacyProduct {'*legacy fixed ProductCode*'} WrongProduct {'*version-specific*ProductCode*'} UpgradeCode {'*stable*UpgradeCode*'} Digest {'*release digest*'} {$_ -in @('MachineScope','DualScope','PerUserFlag','AllUsersZero')} {'*per-user-only MSI authoring*empty ALLUSERS and MSIINSTALLPERUSER*'} default {'*corrected*MSI*'}}
        Assert-Rejected @{version='2.1.7';PrepareMigration=$true} $expected
    }
    $before=$wingetTest.apiCalls
    foreach ($unstable in @('2.1.7-beta.1','2.1.7+build.1','2.1','02.1.6')) {Assert-Rejected @{version=$unstable} '*stable three-part version*'}
    Assert-Rejected @{version='2.1.7';releaseTag='2.1.6'} '*matching release tag*'
    Assert-True ($wingetTest.apiCalls -eq $before) 'Invalid versions must fail before API calls.'
    foreach ($flag in @('draft','prerelease')) {
        Set-Release -Corrected
        $wingetTest.release.$flag=$true
        Assert-Rejected @{version='2.1.7';PrepareMigration=$true} '*published stable GitHub release*'
    }
    foreach ($defect in @('missing','duplicate','empty','pending','wrongUrl')) {
        Set-Release -Corrected
        switch($defect) {
            missing {$wingetTest.release.assets=$wingetTest.release.assets[0..3]}
            duplicate {$wingetTest.release.assets+=$wingetTest.release.assets[0]}
            empty {$wingetTest.release.assets[0].size=0}
            pending {$wingetTest.release.assets[0].state='new'}
            wrongUrl {$wingetTest.release.assets[0].browser_download_url='https://example.org/wrong.zip'}
        }
        Assert-Rejected @{version='2.1.7'} $(if($defect -eq 'wrongUrl'){'*Unexpected download URL*'}else{'*exactly one uploaded, nonempty release asset*'})
    }
    Set-Release -Corrected
    $wingetTest.toolExitCode=19
    Assert-Rejected @{version='2.1.7';outputDirectory="$state/failed";PrepareMigration=$true} '*wingetcreate failed with exit code 19*' -AllowToolCall
    Assert-True (!(Test-Path "$state/failed")) 'Failed tool left usable-looking manifests.'
    $wingetTest.toolExitCode=0; $wingetTest.wrongOutput=$true
    Assert-Rejected @{version='2.1.7';outputDirectory="$state/malformed";PrepareMigration=$true} '*Unexpected package identity/version*' -AllowToolCall
    Assert-True (!(Test-Path "$state/malformed")) 'Malformed output was promoted.'

    # The local-candidate entrypoint shares policy with production while doing
    # neither release lookup nor publication. Its validator here is a recorder;
    # the actual Windows CI invocation uses real MSI inspection and winget.exe.
    $records=foreach ($number in @('2.1.7','2.1.8')) {
        $msi=Join-Path $state "candidate-$number.msi"; $zip=Join-Path $state "candidate-$number.zip"
        'local msi fixture' | Set-Content $msi; 'local zip fixture' | Set-Content $zip
        @{Version=$number;MsiPath=$msi;ZipPath=$zip;MsiHash=(Get-FileHash $msi).Hash;ZipHash=(Get-FileHash $zip).Hash}
    }
    @{Architecture='x64';InstallerType='wix';Versions=@($records)} | ConvertTo-Json -Depth 5 | Set-Content "$state/inventory.json"
    $before=$wingetTest.apiCalls
    & "$PSScriptRoot/Test-MigrationManifestPreparation.ps1" -InventoryPath "$state/inventory.json" -OutputDirectory "$state/candidate-policy" -MsiMetadataReader Read-TestCandidateMetadata -Winget Invoke-TestWingetValidate
    $summary=@(Get-Content "$state/candidate-policy/summary.json" -Raw | ConvertFrom-Json)
    Assert-True ($summary.Count -eq 2 -and $wingetTest.schemaCalls -eq 2 -and $wingetTest.apiCalls -eq $before) 'Local entrypoint omitted a candidate validation or queried the release API.'
    Assert-True (@($summary | Where-Object Identity -NE 'grate-devs.grate').Count -eq 0) 'Local entrypoint promoted a diagnostic old-ID bridge.'
    Assert-True (@(Get-ChildItem "$state/candidate-policy" -Recurse -Filter '*erikbra*').Count -eq 0) 'Local entrypoint emitted old-ID bridge manifests.'
    $wingetTest.testCount++
    $wingetTest.schemaExitCode=1
    $schemaRejected=$false
    try {
        & "$PSScriptRoot/Test-MigrationManifestPreparation.ps1" -InventoryPath "$state/inventory.json" -OutputDirectory "$state/candidate-schema-warning" -MsiMetadataReader Read-TestCandidateMetadata -Winget Invoke-TestWingetValidate
    } catch {
        if ($_.Exception.Message -notlike '*WinGet schema validation failed*') { throw }
        $schemaRejected=$true
    }
    Assert-True ($schemaRejected -and !(Test-Path "$state/candidate-schema-warning/summary.json")) 'A nonzero schema-warning result was promoted as successful candidate verification.'
    $wingetTest.testCount++
} finally {
    Remove-Item -LiteralPath $state -Recurse -Force -ErrorAction SilentlyContinue
    # Recording native-tool failures must not leak into the caller's shell exit.
    if ($previousNativeExitCode) { $global:LASTEXITCODE = $previousNativeExitCodeValue }
    else { Remove-Variable -Name LASTEXITCODE -Scope Global -ErrorAction SilentlyContinue }
}
Write-Host "PASS: $($wingetTest.testCount) WinGet preparation contract cases."
