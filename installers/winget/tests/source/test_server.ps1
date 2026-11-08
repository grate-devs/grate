#!/usr/bin/env pwsh
# Protocol checks use real loopback HTTPS; Windows CI exercises the actual client.
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot/SourceServer.ps1"
. "$PSScriptRoot/SourceTestHelpers.ps1"
$productCode = '{E281998A-D8A2-4926-AAA3-066EFA4B2E74}'
$upgradeCode = '{98CF60F4-3F43-4ACE-B364-ADBCD893A144}'

function New-TestVersion([string]$Number) {
    return @{PackageVersion=$Number;DefaultLocale=@{PackageLocale='en-US';Publisher='erikbra';PackageName='grate';License='MIT';ShortDescription='SQL migration runner'};Installers=@(@{Architecture='x64';InstallerType='wix';Scope='user';InstallerUrl='https://example.invalid/grate.msi';InstallerSha256=('A'*64);ProductCode=$productCode;AppsAndFeaturesEntries=@(@{DisplayName='grate';Publisher='erikbra';ProductCode=$productCode;UpgradeCode=$upgradeCode})})}
}
function New-TestCatalog {
    return @{SourceIdentifier='GrateMigrationCI';Packages=@(@{PackageIdentifier='erikbra.grate';Versions=@((New-TestVersion '2.0.0'),(New-TestVersion '2.1.6'))},@{PackageIdentifier='grate-devs.grate';Versions=@((New-TestVersion '2.1.6'))})}
}
function Write-TestCatalog($Value) {
    $Value | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath "$directory/catalog.new" -Encoding utf8NoBOM
    Move-Item -LiteralPath "$directory/catalog.new" -Destination "$directory/catalog.json" -Force
}
function New-Selector([string]$Field, [string]$Keyword, [string]$Kind='Exact') {
    return @{PackageMatchField=$Field;RequestMatch=@{KeyWord=$Keyword;MatchType=$Kind}}
}
function Search-TestCatalog($Payload, [int]$Status=200) {
    $response = Invoke-SourceTestRequest $client $server.Url '/manifestSearch' $Payload 'POST' $Status
    $json = $response.Body | ConvertFrom-Json -AsHashtable
    if ($Status -eq 200) { return ,$json.Data }; return $json
}

$directory = Join-Path ([IO.Path]::GetTempPath()) ('grate-rest-source-' + [guid]::NewGuid().ToString('N'))
$server = $null; $client = $null; $certificate = $null
$passed = 0
try {
    $null = New-Item -ItemType Directory "$directory/assets" -Force
    [IO.File]::WriteAllText("$directory/assets/candidate.zip", 'test candidate asset')
    Write-TestCatalog (New-TestCatalog)
    $certificate = New-SourceTestCertificate $directory
    $client = New-SourceTestClient $certificate
    $server = Start-SourceTestProcess "$PSScriptRoot/server.ps1" @('-Catalog',"$directory/catalog.json",'-Assets',"$directory/assets",'-Certificate',"$directory/cert.pem",'-PrivateKey',"$directory/key.pem") $directory $client '/information'

    $info = (Invoke-SourceTestRequest $client $server.Url '/information').Body | ConvertFrom-Json -AsHashtable
    Assert-SourceEqual $info.Data.SourceIdentifier 'GrateMigrationCI' 'Source identity'
    Assert-SourceEqual $info.Data.ServerSupportedVersions @('1.10.0') 'Protocol versions'
    Assert-SourceEqual $info.Data.UnsupportedPackageMatchFields @('NormalizedPackageNameAndPublisher') 'Unsupported fields'
    $packages = Search-TestCatalog @{Query=@{KeyWord='grate';MatchType='Substring'}}
    Assert-SourceEqual @($packages.PackageIdentifier) @('erikbra.grate','grate-devs.grate') 'Both distinct identities'
    Assert-SourceEqual @($packages[0].Versions.PackageVersion) @('2.0.0','2.1.6') 'All versions remain visible'; $passed++

    $incomplete = [Net.Sockets.TcpClient]::new()
    try {
        $incomplete.Connect('127.0.0.1',([uri]$server.Url).Port)
        $null = Invoke-SourceTestRequest $client $server.Url '/information'; $passed++
    } finally { $incomplete.Dispose() }

    $untrusted = New-SourceTestClient $null
    try {
        $rejected = $false
        try { $null = $untrusted.GetAsync($server.Url+'/information').GetAwaiter().GetResult() } catch { $rejected = $true }
        Assert-SourceEqual $rejected $true 'Untrusted certificate rejected'; $passed++
    } finally { $untrusted.Dispose() }
    $connection = [Net.Sockets.TcpClient]::new(); $tls = $null
    try {
        $connection.Connect('127.0.0.1',([uri]$server.Url).Port)
        $tls = [Net.Security.SslStream]::new($connection.GetStream())
        $options = [Net.Security.SslClientAuthenticationOptions]::new(); $options.TargetHost = 'wrong-host.invalid'
        $options.CertificateChainPolicy = [Security.Cryptography.X509Certificates.X509ChainPolicy]::new()
        $options.CertificateChainPolicy.TrustMode = [Security.Cryptography.X509Certificates.X509ChainTrustMode]::CustomRootTrust
        [void]$options.CertificateChainPolicy.CustomTrustStore.Add($certificate)
        $options.CertificateChainPolicy.RevocationMode = [Security.Cryptography.X509Certificates.X509RevocationMode]::NoCheck
        $rejected = $false
        try { $tls.AuthenticateAsClient($options) } catch { $rejected = $true }
        Assert-SourceEqual $rejected $true 'Wrong certificate host rejected'; $passed++
    } finally { if ($tls) { $tls.Dispose() }; $connection.Dispose() }

    Assert-SourceEqual @((Search-TestCatalog @{Filters=@((New-Selector 'PackageIdentifier' 'grate-devs.grate'))}).PackageIdentifier) @('grate-devs.grate') 'Exact identifier isolates package'
    Assert-SourceEqual (Search-TestCatalog @{Filters=@((New-Selector 'PackageIdentifier' 'GRATE-DEVS.GRATE'))}).Count 0 'Ordinary Exact remains case sensitive'
    Assert-SourceEqual (Search-TestCatalog @{Filters=@((New-Selector 'PackageIdentifier' 'GRATE-DEVS.GRATE' 'CaseInsensitive'))}).Count 1 'Explicit case insensitive matching'; $passed++

    foreach ($case in @(@('StartsWith','GRATE-DEVS',1),@('Wildcard','GRATE-DEV[!x].GR?TE',1),@('Wildcard','grate-dev[x].grate',0),@('Wildcard','grate[',0),@('Wildcard','grate-dev[z-a].grate',0))) {
        Assert-SourceEqual (Search-TestCatalog @{Filters=@((New-Selector 'PackageIdentifier' $case[1] $case[0]))}).Count $case[2] 'Supported selector matching'
    }
    Assert-SourceEqual (Test-SourceValue '1' @{KeyWord='[z-a0-9]';MatchType='Wildcard'}) $true 'Invalid range does not hide remaining valid wildcard members'; $passed++

    $packages = Search-TestCatalog @{Inclusions=@((New-Selector 'PackageIdentifier' 'missing.package'),(New-Selector 'PackageIdentifier' 'erikbra.grate'));Filters=@((New-Selector 'PackageName' 'grate'),(New-Selector 'Market' 'NO'))}
    Assert-SourceEqual @($packages.PackageIdentifier) @('erikbra.grate') 'Inclusions are OR and filters are AND'
    Assert-SourceEqual (Search-TestCatalog @{Filters=@((New-Selector 'PackageIdentifier' 'erikbra.grate'),(New-Selector 'PackageName' 'different'))}).Count 0 'Every filter must match'; $passed++

    foreach ($mapping in @(@('ProductCode',$productCode,'ProductCodes'),@('UpgradeCode',$upgradeCode,'UpgradeCodes'))) {
        foreach ($kind in @('Inclusions','Filters')) {
            $packages = Search-TestCatalog @{$kind=@((New-Selector $mapping[0] $mapping[1].ToLowerInvariant()))}
            Assert-SourceEqual $packages.Count 2 "$kind $($mapping[0]) exposes every MSI collision"
            Assert-SourceEqual $packages[0].Versions[0][$mapping[2]] @($mapping[1].ToLowerInvariant()) 'Search references are folded'
            Assert-SourceEqual (Search-TestCatalog @{$kind=@((New-Selector $mapping[0] '{00000000-0000-0000-0000-000000000000}'))}).Count 0 'Unrelated MSI reference excluded'
        }
    }; $passed++

    foreach ($payload in @(@{Inclusions=@((New-Selector 'NormalizedPackageNameAndPublisher' 'grate'))},@{Filters=@((New-Selector 'NormalizedPackageNameAndPublisher' 'grate'))},@{Inclusions=@((New-Selector 'ProductCode' $productCode),(New-Selector 'NormalizedPackageNameAndPublisher' 'grate'))})) {
        $result = Search-TestCatalog $payload 400
        if ($result.message -notlike '*Unsupported match field: NormalizedPackageNameAndPublisher*') { throw "Missing unsupported-field error: $($result.message)" }
    }; $passed++

    $updated = New-TestCatalog
    foreach ($package in $updated.Packages) { foreach ($version in $package.Versions) { $version.Installers[0].PackageFamilyName='Publisher.Grate_abC123' } }
    Write-TestCatalog $updated
    $packages = Search-TestCatalog @{Filters=@((New-Selector 'PackageFamilyName' 'publisher.grate_abc123'))}
    Assert-SourceEqual $packages.Count 2 'Package family is a case insensitive Windows reference'
    Assert-SourceEqual $packages[0].Versions[0].PackageFamilyNames @('publisher.grate_abc123') 'Package family search output is folded'
    Assert-SourceEqual (Search-TestCatalog @{Filters=@((New-Selector 'PackageName' 'GRATE'))}).Count 0 'Ordinary name Exact remains case sensitive'; $passed++
    Write-TestCatalog (New-TestCatalog)

    $manifest = (Invoke-SourceTestRequest $client $server.Url '/packageManifests/erikbra.grate?Version=2.0.0').Body | ConvertFrom-Json -AsHashtable
    Assert-SourceEqual @($manifest.Data.Versions.PackageVersion) @('2.0.0') 'Version filter'
    Assert-SourceEqual $manifest.Data.Versions[0].Installers[0].ProductCode $productCode 'Manifest preserves authored GUID case'
    Assert-SourceEqual $manifest.Data.Versions[0].Installers[0].AppsAndFeaturesEntries[0].UpgradeCode $upgradeCode 'Manifest retains installer metadata'
    $null = Invoke-SourceTestRequest $client $server.Url '/packageManifests/erikbra.grate?Version=9.9.9' $null 'GET' 404; $passed++

    $updated = New-TestCatalog; $updated.Packages[1].Versions += New-TestVersion '2.1.7'; Write-TestCatalog $updated
    Assert-SourceEqual @((Search-TestCatalog @{Filters=@((New-Selector 'PackageIdentifier' 'grate-devs.grate'))})[0].Versions.PackageVersion) @('2.1.6','2.1.7') 'Catalog reload exposes upgrade'
    $updated.SourceIdentifier='ChangedIdentity'; Write-TestCatalog $updated
    $null = Invoke-SourceTestRequest $client $server.Url '/packageManifests/grate-devs.grate' $null 'GET' 500
    Assert-SourceEqual (((Invoke-SourceTestRequest $client $server.Url '/information').Body | ConvertFrom-Json).Data.SourceIdentifier) 'GrateMigrationCI' 'Information identity remains fixed'; $passed++
    Write-TestCatalog (New-TestCatalog)

    $asset = Invoke-SourceTestRequest $client $server.Url '/assets/candidate.zip'
    Assert-SourceEqual $asset.Body 'test candidate asset' 'Asset content'
    Assert-SourceEqual $asset.ContentType 'application/zip' 'Asset MIME type'
    $head = Invoke-SourceTestRequest $client $server.Url '/assets/candidate.zip' $null 'HEAD'
    Assert-SourceEqual $head.Length 20L 'HEAD reports asset length'; Assert-SourceEqual $head.Body '' 'HEAD has no body'
    foreach ($path in @('/assets/../catalog.json','/assets/%2e%2e/catalog.json','/assets/missing.zip')) { $null = Invoke-SourceTestRequest $client $server.Url $path $null 'GET' 404 }; $passed++

    $null = Search-TestCatalog @{Filters=@((New-Selector 'NotASupportedField' 'grate'))} 400
    $null = Search-TestCatalog @{MaximumResults=1;FetchAllManifests=$true} 400; $passed++
    foreach ($duplicate in @('version','channel','identifier')) {
        $invalid = New-TestCatalog
        if ($duplicate -in @('version','channel')) {
            $extra = New-TestVersion '2.0.0'
            if ($duplicate -eq 'channel') { $extra.Channel = '' }
            $invalid.Packages[0].Versions += $extra
        } else { $invalid.Packages += $invalid.Packages[0] }
        Write-TestCatalog $invalid; $rejected = $false
        try { $null = Read-SourceCatalog "$directory/catalog.json" } catch { if ($_.Exception.Message -like '*Duplicate*') { $rejected=$true } else { throw } }
        Assert-SourceEqual $rejected $true "Duplicate $duplicate rejected"
    }; $passed++
    Move-Item -LiteralPath "$directory/catalog.json" -Destination "$directory/catalog.saved"
    $missing = Search-TestCatalog @{} 500
    Assert-SourceEqual $missing.code 'InvalidCatalog' 'Catalog I/O failure is a server error'
    $null = Invoke-SourceTestRequest $client $server.Url '/packageManifests/grate-devs.grate' $null 'GET' 500; $passed++
    Write-Host "PASS: $passed REST source protocol scenarios over HTTPS."
} finally {
    Stop-SourceTestProcess $server
    if ($client) { $client.Dispose() }; if ($certificate) { $certificate.Dispose() }
    Remove-Item -LiteralPath $directory -Recurse -Force -ErrorAction SilentlyContinue
}
