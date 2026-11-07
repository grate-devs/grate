#!/usr/bin/env pwsh
# Exercise real Skopeo digest preservation using local OCI layouts only.
# No registry is contacted, no image is published and no credential is used.
[CmdletBinding()]
param()
. "$PSScriptRoot/release_common.ps1"

function Write-OciCopyBlob([string]$Root, $Value, [string]$MediaType) {
    $bytes = Get-JsonBytes $Value
    $digest = Get-ByteDigest $bytes
    $blobDirectory = Join-Path $Root 'blobs/sha256'
    $null = [IO.Directory]::CreateDirectory($blobDirectory)
    [IO.File]::WriteAllBytes((Join-Path $blobDirectory $digest.Substring(7)), $bytes)
    return @{mediaType=$MediaType;digest=$digest;size=$bytes.Length}
}

function New-OciCopyFixture([string]$Root) {
    $null = [IO.Directory]::CreateDirectory($Root)
    [IO.File]::WriteAllText((Join-Path $Root 'oci-layout'), '{"imageLayoutVersion":"1.0.0"}')
    $descriptors = @(foreach ($architecture in @('amd64','arm64')) {
        $config = Write-OciCopyBlob $Root @{architecture=$architecture;os='linux';rootfs=@{type='layers';diff_ids=@()}} 'application/vnd.oci.image.config.v1+json'
        $manifest = Write-OciCopyBlob $Root @{schemaVersion=2;mediaType='application/vnd.oci.image.manifest.v1+json';config=$config;layers=@()} 'application/vnd.oci.image.manifest.v1+json'
        $manifest.platform = @{architecture=$architecture;os='linux'}
        $manifest
    })
    $config = Write-OciCopyBlob $Root @{architecture='unknown';os='unknown';rootfs=@{type='layers';diff_ids=@()}} 'application/vnd.oci.image.config.v1+json'
    $statement = Write-OciCopyBlob $Root @{_type='https://in-toto.io/Statement/v0.1';predicate=@{}} 'application/vnd.in-toto+json'
    $attestation = Write-OciCopyBlob $Root @{schemaVersion=2;mediaType='application/vnd.oci.image.manifest.v1+json';config=$config;layers=@($statement)} 'application/vnd.oci.image.manifest.v1+json'
    $attestation.platform = @{architecture='unknown';os='unknown'}
    $attestation.annotations = @{'vnd.docker.reference.type'='attestation-manifest';'vnd.docker.reference.digest'=$descriptors[0].digest}
    $descriptors += $attestation
    $index = Write-OciCopyBlob $Root @{schemaVersion=2;mediaType='application/vnd.oci.image.index.v1+json';manifests=$descriptors} 'application/vnd.oci.image.index.v1+json'
    $index.annotations = @{'org.opencontainers.image.ref.name'='3.0.0'}
    [IO.File]::WriteAllBytes((Join-Path $Root 'index.json'), (Get-JsonBytes @{schemaVersion=2;manifests=@($index)}))
    return $index.digest
}

function Invoke-OciCopyCheck {
    $root = Join-Path ([IO.Path]::GetTempPath()) ('grate offline OCI copy ' + [guid]::NewGuid().ToString('N'))
    try {
        $source = Join-Path $root 'canonical'; $destination = Join-Path $root 'compatibility'
        $expected = New-OciCopyFixture $source
        $version = Invoke-ReleaseProcess 'skopeo' @('--version') 30
        if ($version.ExitCode -ne 0) { throw 'Skopeo version check failed.' }
        $copy = Invoke-ReleaseProcess 'skopeo' @('copy','--all','--preserve-digests',"oci:${source}:3.0.0","oci:${destination}:3.0.0") 60
        if ($copy.ExitCode -ne 0) { throw 'Skopeo local OCI copy failed.' }
        $raw = Invoke-ReleaseProcess 'skopeo' @('inspect','--raw',"oci:${destination}:3.0.0") 30
        if ($raw.ExitCode -ne 0) { throw 'Skopeo local OCI inspection failed.' }
        $actual = Get-ByteDigest $raw.Bytes
        if ($actual -cne $expected) { throw "Copied index digest differs: expected $expected, got $actual." }
        foreach ($blob in Get-ChildItem -LiteralPath (Join-Path $source 'blobs/sha256') -File) {
            $copied = [IO.File]::ReadAllBytes((Join-Path $destination "blobs/sha256/$($blob.Name)"))
            if ((Get-ByteDigest $copied) -cne ('sha256:'+$blob.Name)) { throw "Copied blob differs: $($blob.Name)" }
        }
        $index = [Text.Encoding]::UTF8.GetString($raw.Bytes) | ConvertFrom-Json -AsHashtable
        if ($index.manifests.Count -ne 3) { throw 'Expected two platform manifests and one attestation.' }
        @{status='verified';tool=$version.Text.Trim();digest=$actual;platforms=@('linux/amd64','linux/arm64');attestations=1;registry_publication=$false} | ConvertTo-Json -Depth 10
    } finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
}

if ($MyInvocation.InvocationName -ne '.') { Invoke-OciCopyCheck }
