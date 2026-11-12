#!/usr/bin/env pwsh
# Install pinned publication/test clients into a new directory, without changing PATH.
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$Destination,
    [ValidateSet('linux-x64', 'osx-arm64')]
    [string]$RuntimeIdentifier = 'linux-x64',
    [switch]$IncludeKind
)

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true
$destinationPath = [IO.Path]::GetFullPath($Destination)
if (Test-Path -LiteralPath $destinationPath) {
    throw "Use a new directory for the Kubernetes test clients: $destinationPath"
}
$platform = if ($RuntimeIdentifier -eq 'osx-arm64') {
    'darwin-arm64'
}
else {
    'linux-amd64'
}
$download = Join-Path ([IO.Path]::GetTempPath()) "grate-kubernetes-tools-$([Guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Path $download, $destinationPath | Out-Null
try {
    $helmVersion = '4.2.0'
    $archive = Join-Path $download 'helm.tar.gz'
    $helmUrl = "https://get.helm.sh/helm-v$helmVersion-$platform.tar.gz"
    Invoke-WebRequest -Uri "$helmUrl.sha256" -OutFile "$archive.sha256"
    Invoke-WebRequest -Uri $helmUrl -OutFile $archive
    $expected = (Get-Content -LiteralPath "$archive.sha256" -Raw).Trim()
    if ($expected -notmatch '^[0-9a-fA-F]{64}$' -or
        (Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash -ine $expected) {
        throw 'The Helm archive does not match its SHA256 checksum.'
    }
    tar -xzf $archive -C $download
    $helm = Join-Path $destinationPath 'helm'
    Move-Item -LiteralPath (Join-Path $download "$platform/helm") -Destination $helm
    $actualHelm = (& $helm version --short).Trim()
    if ($actualHelm -notmatch '^v4\.2\.0(\+|$)') {
        throw "Unexpected Helm version: $actualHelm"
    }

    $kind = $null
    if ($IncludeKind) {
        $kindVersion = '0.33.0'
        $kind = Join-Path $destinationPath 'kind'
        $kindUrl = "https://github.com/kubernetes-sigs/kind/releases/download/v$kindVersion/kind-$platform"
        Invoke-WebRequest -Uri "$kindUrl.sha256sum" -OutFile (Join-Path $download 'kind.sha256')
        Invoke-WebRequest -Uri $kindUrl -OutFile $kind
        $expectedKind = ((Get-Content -LiteralPath (Join-Path $download 'kind.sha256') -Raw).Trim() -split '\s+')[0]
        if ($expectedKind -notmatch '^[0-9a-fA-F]{64}$' -or
            (Get-FileHash -LiteralPath $kind -Algorithm SHA256).Hash -ine $expectedKind) {
            throw 'The kind executable does not match its SHA256 checksum.'
        }
        chmod +x $kind
        $actualKind = (& $kind version).Trim()
        if ($actualKind -notmatch '^kind v0\.33\.0( |$)') {
            throw "Unexpected kind version: $actualKind"
        }
    }
    [pscustomobject]@{
        HelmPath = $helm
        KindPath = $kind
    }
}
catch {
    Remove-Item -LiteralPath $destinationPath -Recurse -Force
    throw
}
finally {
    Remove-Item -LiteralPath $download -Recurse -Force
}
