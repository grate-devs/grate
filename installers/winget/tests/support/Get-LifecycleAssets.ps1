#!/usr/bin/env pwsh
param (
    [Parameter(Mandatory)][ValidateSet('x86', 'x64', 'arm64')][string]$Architecture,
    [Parameter(Mandatory)][ValidateSet('zip', 'wix')][string]$InstallerType,
    [Parameter(Mandatory)][string]$CandidateDirectory,
    [Parameter(Mandatory)][string]$OutputDirectory,
    [string]$ReleaseCandidateVersion
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
if (!$IsWindows -or $env:GITHUB_ACTIONS -ne 'true' -or $env:RUNNER_ENVIRONMENT -ne 'github-hosted') {
    throw 'Lifecycle asset preparation requires a disposable GitHub-hosted Windows runner.'
}
$OutputDirectory = [IO.Path]::GetFullPath($OutputDirectory)
$assets = Join-Path $OutputDirectory 'assets'
New-Item -ItemType Directory -Force $assets | Out-Null
$headers = @{ Accept = 'application/vnd.github+json' }
if ($env:GH_TOKEN) { $headers.Authorization = "Bearer $env:GH_TOKEN" }
$requestedVersions = if ($ReleaseCandidateVersion) { @('2.0.0', $ReleaseCandidateVersion) } else { @('2.0.0', '2.1.6', '2.1.7', '2.1.8') }
$versions = foreach ($version in $requestedVersions) {
    $zip = Join-Path $assets "grate-$version.zip"
    $msi = Join-Path $assets "grate-$version.msi"
    if ($version -in @('2.1.7','2.1.8')) {
        # Fixture version of the current source, built only for this test run.
        $name = if ($version -eq '2.1.7') { 'grate' } else { 'grate-next' }
        Copy-Item "$CandidateDirectory/$name.zip" $zip
        if ($InstallerType -eq 'wix') { Copy-Item "$CandidateDirectory/$name.msi" $msi }
    } else {
        $release = Invoke-RestMethod "https://api.github.com/repos/grate-devs/grate/releases/tags/$version" -Headers $headers
        $requested = @(@{Name="grate-win-$Architecture-self-contained-$version.zip"; Path=$zip})
        if ($InstallerType -eq 'wix') { $requested += @{Name="grate-msi-win-$Architecture-$version.msi"; Path=$msi} }
        foreach ($item in $requested) {
            $found = @($release.assets | Where-Object name -CEQ $item.Name)
            if ($found.Count -ne 1) { throw "Expected one release asset $($item.Name)." }
            Invoke-WebRequest $found[0].browser_download_url -OutFile $item.Path
            if ('sha256:' + (Get-FileHash $item.Path -Algorithm SHA256).Hash.ToLowerInvariant() -cne $found[0].digest) {
                throw "Release digest mismatch: $($item.Name)"
            }
        }
    }
    $extracted = Join-Path $OutputDirectory "payload-$version"
    Expand-Archive -LiteralPath $zip -DestinationPath $extracted -Force
    $record = [ordered]@{
        Version = $version; ZipPath = $zip; Executable = (Join-Path $extracted 'grate.exe')
        ZipHash = (Get-FileHash $zip -Algorithm SHA256).Hash
    }
    if ($InstallerType -eq 'wix') {
        $record.MsiPath = $msi
        $record.MsiHash = (Get-FileHash $msi -Algorithm SHA256).Hash
        $record.MsiMetadata = & "$PSScriptRoot/../../../msi/helpers/Get-InstallerMetadata.ps1" -MsiPath $msi
    }
    [pscustomobject]$record
}
@{ Architecture = $Architecture; InstallerType = $InstallerType; Versions = @($versions) } |
    ConvertTo-Json -Depth 10 | Set-Content "$OutputDirectory/inventory.json"
Write-Host "Prepared verified $InstallerType $Architecture historical assets and current-source test candidate."
