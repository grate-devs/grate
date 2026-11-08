#!/usr/bin/env pwsh
. "$PSScriptRoot/migrate_docker_tags.ps1"
. "$PSScriptRoot/release_test_helpers.ps1"
function New-TestImage([string]$Digest, [string[]]$Architectures = @('amd64')) {
    @{ digest=$Digest; manifests=@($Digest); blobs=@('sha256:blob'); platforms=@($Architectures | ForEach-Object { @{os='linux';architecture=$_} }); attestations=@() }
}
function Reset-MigrationFixture {
    $script:Images = @{ '1.8.0'=(New-TestImage 'sha256:old');'2.1.6'=(New-TestImage 'sha256:new' @('amd64','arm64')); latest=(New-TestImage 'sha256:new' @('amd64','arm64')) }
    $script:SourceRegistry = @{ Tags = $script:Images | ConvertTo-Json -Depth 30 | ConvertFrom-Json -AsHashtable }
    $script:DestinationRegistry = @{ Tags=@{}; BlobChecks=[Collections.Generic.List[string]]::new() }
    $script:Snapshot = @{ source='erikbra/grate';destination='gratedevs/grate';tags=$script:Images | ConvertTo-Json -Depth 30 | ConvertFrom-Json -AsHashtable }
    $script:Copies = [Collections.Generic.List[object]]::new()
    $script:FixtureDirectory = New-TestDirectory
    $script:ResultPath = Join-Path $script:FixtureDirectory 'result.json'
}
function Get-DockerTagNames([string]$Repository) { if ($Repository -ceq 'erikbra/grate') { $script:SourceRegistry.Tags.Keys } else { $script:DestinationRegistry.Tags.Keys } }
function Get-RegistryDigest($Registry,[string]$Tag) { $Registry.Tags[$Tag].digest }
function Get-RegistryDescription($Registry,[string]$Reference,[switch]$CheckBlobs) {
    if ($CheckBlobs) { $Registry.BlobChecks.Add($Reference) }
    $Registry.Tags[$Reference] | ConvertTo-Json -Depth 30 | ConvertFrom-Json -AsHashtable
}
function Copy-TestImage([string]$Digest,[string]$Tag) { $script:Copies.Add(@($Digest,$Tag)); $script:DestinationRegistry.Tags[$Tag] = $script:Images[$Tag] | ConvertTo-Json -Depth 30 | ConvertFrom-Json -AsHashtable }
function Invoke-HistoryCopy([scriptblock]$CopyAction = { param($Digest,$Tag) Copy-TestImage $Digest $Tag }) { Copy-AndVerifyDockerHistory $script:Snapshot $script:SourceRegistry $script:DestinationRegistry $script:ResultPath $CopyAction }
function Invoke-MigrationCase([string]$Name,[scriptblock]$CaseBody) {
    Invoke-Test $Name { Reset-MigrationFixture; try { & $CaseBody } finally { [IO.Directory]::Delete($script:FixtureDirectory,$true) } }
}
Invoke-MigrationCase 'frozen digests are copied and latest verified last' {
    $result = Invoke-HistoryCopy
    Assert-Equal @(@('sha256:old','1.8.0'),@('sha256:new','2.1.6'),@('sha256:new','latest')) @($script:Copies)
    Assert-Equal 'latest' $script:DestinationRegistry.BlobChecks[-1]
    Assert-Equal 'verified' $result.status
    Assert-Equal $script:Images['2.1.6'].platforms $result.tags['2.1.6'].platforms
}
Invoke-MigrationCase 'conflicting later tag prevents all writes' {
    $script:DestinationRegistry.Tags['2.1.6'] = New-TestImage 'sha256:different'
    Assert-Throws { Invoke-HistoryCopy } '*conflicting*'
    Assert-Equal 0 $script:Copies.Count
}
Invoke-MigrationCase 'source movement prevents writes' {
    $script:SourceRegistry.Tags.latest = New-TestImage 'sha256:moved'
    Assert-Throws { Invoke-HistoryCopy } '*moved*'
    Assert-Equal 0 $script:Copies.Count
}
Invoke-MigrationCase 'source inventory change prevents writes' {
    $script:SourceRegistry.Tags['new'] = New-TestImage 'sha256:new'
    Assert-Throws { Invoke-HistoryCopy } '*inventory changed*'
    Assert-Equal 0 $script:Copies.Count
}
Invoke-MigrationCase 'matching existing graph is checked without recopy' {
    $script:DestinationRegistry.Tags = $script:Images | ConvertTo-Json -Depth 30 | ConvertFrom-Json -AsHashtable
    $result = Invoke-HistoryCopy
    Assert-Equal 0 $script:Copies.Count
    Assert-Equal 3 $script:DestinationRegistry.BlobChecks.Count
    Assert-True (@($result.tags.Values | Where-Object action -cne 'already_present').Count -eq 0)
}
Invoke-MigrationCase 'matching root digest cannot hide missing platform' {
    Assert-Throws { Invoke-HistoryCopy { param($Digest,$Tag) Copy-TestImage $Digest $Tag; if ($Tag -ceq '2.1.6') { $script:DestinationRegistry.Tags[$Tag].platforms=@() } } } '*mismatch*'
    $report = Get-Content -LiteralPath $script:ResultPath -Raw | ConvertFrom-Json -AsHashtable
    Assert-Equal 'failed' $report.status
    Assert-True (!$report.tags.ContainsKey('2.1.6'))
    Assert-True (!$script:DestinationRegistry.Tags.ContainsKey('latest'))
}
Invoke-MigrationCase 'final source movement cannot pass' {
    Assert-Throws { Invoke-HistoryCopy { param($Digest,$Tag) Copy-TestImage $Digest $Tag; if ($Tag -ceq 'latest') { $script:SourceRegistry.Tags.latest=New-TestImage 'sha256:moved' } } } '*moved*'
    Assert-Equal 'failed' (Get-Content -LiteralPath $script:ResultPath -Raw | ConvertFrom-Json -AsHashtable).status
}
Invoke-MigrationCase 'final destination movement cannot pass' {
    Assert-Throws { Invoke-HistoryCopy { param($Digest,$Tag) Copy-TestImage $Digest $Tag; if ($Tag -ceq 'latest') { $script:DestinationRegistry.Tags['1.8.0']=New-TestImage 'sha256:moved' } } } '*Destination tag moved*'
}
Invoke-MigrationCase 'snapshot retains Docker tags differing only in case' {
    $script:SourceRegistry.Tags = [Collections.Hashtable]::new([StringComparer]::Ordinal)
    $script:SourceRegistry.Tags['Foo'] = New-TestImage 'sha256:uppercase'
    $script:SourceRegistry.Tags['foo'] = New-TestImage 'sha256:lowercase'
    $result = Get-DockerMigrationSnapshot $script:SourceRegistry $script:DestinationRegistry
    Assert-Equal 2 $result.tags.Count
    Assert-Equal 'sha256:uppercase' $result.tags['Foo'].digest
    Assert-Equal 'sha256:lowercase' $result.tags['foo'].digest
}
Invoke-MigrationCase 'copy CLI uses private temporary auth and immutable source then removes it' {
    $planPath = Join-Path $script:FixtureDirectory 'plan.json'
    Write-ReleaseJson $planPath $script:Snapshot
    $script:AuthPaths = [Collections.Generic.List[string]]::new()
    function New-Registry([string]$Repository) { if ($Repository -ceq 'erikbra/grate') { $script:SourceRegistry } else { $script:DestinationRegistry } }
    function Invoke-Skopeo([string[]]$Arguments,[string]$Operation) {
        $authPath=$Arguments[[Array]::IndexOf($Arguments,'--authfile')+1]
        $script:AuthPaths.Add($authPath)
        if (!$IsWindows) { Assert-Equal ([IO.UnixFileMode]::UserRead -bor [IO.UnixFileMode]::UserWrite) ([IO.File]::GetUnixFileMode($authPath)) }
        Assert-True ($Arguments -contains '--all'); Assert-True ($Arguments -contains '--preserve-digests')
        Assert-True ($Arguments[-2].Contains('@sha256:'))
        Assert-True (!(($Arguments -join ' ').Contains('FAKE_TOKEN')))
        $tag=$Arguments[-1].Split(':')[-1]
        Copy-TestImage $script:Images[$tag].digest $tag
    }
    # Stub only command discovery, never invoke the discovered command.
    function Get-Command { 'skopeo' }
    $oldUser=$env:DOCKER_HUB_USER; $oldToken=$env:DOCKER_HUB_TOKEN
    try { $env:DOCKER_HUB_USER='FAKE_USER'; $env:DOCKER_HUB_TOKEN='FAKE_TOKEN'; Invoke-DockerMigration $script:FixtureDirectory $planPath $true $false }
    finally { $env:DOCKER_HUB_USER=$oldUser; $env:DOCKER_HUB_TOKEN=$oldToken }
    Assert-Equal 3 $script:AuthPaths.Count
    Assert-True (@($script:AuthPaths | Where-Object { [IO.File]::Exists($_) }).Count -eq 0)
}
# Restore real graph traversal for manifest-specific tests.
. "$PSScriptRoot/release_common.ps1"
Invoke-Test 'single manifest obtains platform from config and checks every blob' {
    $registry=New-Registry 'erikbra/grate'
    function Get-RegistryManifest { @{Digest='sha256:root';Data=@{schemaVersion=2;config=@{digest='sha256:config'};layers=@(@{digest='sha256:layer'})}} }
    function Get-RegistryConfig { @{os='linux';architecture='amd64'} }
    $script:BlobsChecked=[Collections.Generic.List[string]]::new()
    function Test-RegistryBlob($Registry,[string]$Digest) { $script:BlobsChecked.Add($Digest) }
    $result=Get-RegistryDescription $registry '1.8.0' -CheckBlobs
    Assert-Equal @(@{os='linux';architecture='amd64'}) $result.platforms
    Assert-Equal 2 $script:BlobsChecked.Count
}
Invoke-Test 'index retains attestations separately from runnable platforms' {
    $registry=New-Registry 'erikbra/grate'
    function Get-RegistryManifest($Registry,[string]$Reference) {
        if ($Reference -cin @('tag','sha256:index')) { return @{Digest='sha256:index';Data=@{schemaVersion=2;manifests=@(@{digest='sha256:amd64';platform=@{os='linux';architecture='amd64'}},@{digest='sha256:attestation';platform=@{os='unknown';architecture='unknown'};annotations=@{'vnd.docker.reference.type'='attestation-manifest'}})}} }
        @{Digest=$Reference;Data=@{schemaVersion=2;config=@{digest='sha256:config'};layers=@()}}
    }
    $result=Get-RegistryDescription $registry 'tag'
    Assert-Equal @(@{os='linux';architecture='amd64'}) $result.platforms
    Assert-Equal @('sha256:attestation') $result.attestations
    Assert-Equal 3 $result.manifests.Count
}
Write-Host "$script:TestCount migration checks passed."
