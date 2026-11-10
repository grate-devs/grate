param(
    [Parameter(Mandatory)][string]$Version,
    [Parameter(Mandatory)][string]$ReleaseRunId,
    [Parameter(Mandatory)][ValidateSet('All', 'SQLite', 'SQLServer', 'MariaDB', 'PostgreSQL', 'Oracle')][string]$Distribution,
    [Parameter(Mandatory)][ValidateSet('winget', 'chocolatey')][string]$Channel,
    [ValidateSet('x86', 'x64', 'arm64')][string]$Architecture = 'x64',
    [ValidateSet('zip', 'wix')][string]$InstallerType = 'zip',
    [Parameter(Mandatory)][string]$CandidateDirectory,
    [Parameter(Mandatory)][string]$OutputDirectory,
    [string]$Winget
)
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true
. "$PSScriptRoot/windows_channel_common.ps1"
if (!$IsWindows -or $env:GITHUB_ACTIONS -ne 'true' -or $env:RUNNER_ENVIRONMENT -ne 'github-hosted') {
    throw 'Native channel verification requires a disposable GitHub-hosted Windows runner.'
}
$CandidateDirectory = [IO.Path]::GetFullPath($CandidateDirectory)
$OutputDirectory = [IO.Path]::GetFullPath($OutputDirectory)
New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
$context = Get-WindowsChannelReleaseContext -Version $Version -ReleaseRunId $ReleaseRunId
$profile = Get-GrateDistribution -Name $Distribution
$id = $profile.PackageId
$packageId = if ($Distribution -eq 'All') { 'grate-devs.grate' } else { "grate-devs.grate.$Distribution" }
$zipName = "$id-win-$Architecture-self-contained-$Version.zip"
$zip = Save-WindowsChannelReleaseAsset -Context $context -Name $zipName -Directory "$OutputDirectory/assets"
$manifest = Save-WindowsChannelReleaseAsset -Context $context -Name 'release-manifest.json' -Directory "$OutputDirectory/assets"
$inventory = Get-Content -LiteralPath $manifest -Raw | ConvertFrom-Json
$payloadRecord = @($inventory.assets | Where-Object name -CEQ $zipName)
if ($inventory.version -cne $Version -or $inventory.tag -cne $Version -or $payloadRecord.Count -ne 1 -or
    (Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash.ToLowerInvariant() -cne $payloadRecord[0].sha256) {
    throw 'Public payload does not match the final release manifest.'
}
$expectedDirectory = "$OutputDirectory/public-payload"
Expand-Archive -LiteralPath $zip -DestinationPath $expectedDirectory
$expected = "$expectedDirectory/grate.exe"
$packageHash = $null
$manifestHashes = @()
$legacyMigration = 'not applicable; separate slim identity'
$ownsInstall = $false
try {
    if ($Channel -eq 'winget') {
        if (!$Winget -or (Get-Command grate -ErrorAction SilentlyContinue) -or
            (Test-Path -LiteralPath "$env:LOCALAPPDATA/erikbra/grate")) {
            throw 'A pinned WinGet and clean disposable installation state are required.'
        }
        $provenance = Get-Content -LiteralPath "$CandidateDirectory/provenance.json" -Raw | ConvertFrom-Json
        if ($provenance.SourceCommit -cne $context.SourceCommit -or $provenance.Version -cne $Version -or
            $provenance.ReleaseTag -cne $Version -or [string]$provenance.RunId -cne $ReleaseRunId -or
            $provenance.PackageIdentifier -cne $packageId -or !$provenance.SchemaValidated -or $provenance.Submitted) {
            throw 'WinGet candidate provenance does not match the original release.'
        }
        $path = if ($Distribution -eq 'All') { 'grate' } else { "grate/$Distribution" }
        $candidate = "$CandidateDirectory/manifests/g/grate-devs/$path/$Version"
        $files = @(Get-ChildItem -LiteralPath $candidate -Filter '*.yaml' -File)
        if ($files.Count -ne 3) {
            throw 'A complete three-file submission manifest is required.'
        }
        foreach ($file in $files) {
            $text = Get-Content -LiteralPath $file.FullName -Raw
            if ($text -cnotmatch "(?m)^PackageIdentifier: $([regex]::Escape($packageId))\r?$" -or
                $text -cnotmatch "(?m)^PackageVersion: $([regex]::Escape($Version))\r?$") {
                throw 'Unexpected manifest package identity or version.'
            }
            $manifestHashes += [pscustomobject]@{ Name = $file.Name; Sha256 = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash }
        }
        if ($Distribution -eq 'All') {
            $legacyRoot = "$OutputDirectory/legacy-migration"
            & "$PSScriptRoot/../../installers/winget/tests/support/Get-LifecycleAssets.ps1" -Architecture $Architecture -InstallerType $InstallerType -CandidateDirectory $CandidateDirectory -OutputDirectory $legacyRoot -ReleaseCandidateVersion $Version
            & "$PSScriptRoot/../../installers/winget/tests/Test-WinGetLifecycle.ps1" -Winget $Winget -InventoryPath "$legacyRoot/inventory.json" -OutputDirectory "$legacyRoot/lifecycle" -SourceType PreIndexed -PublicBaseline -ReleaseCandidateVersion $Version
            $legacyMigration = 'passed; actual public 2.0.0 to final release through private PreIndexed source'
        }
        Invoke-WindowsChannelCommand -FilePath $Winget -Arguments @('validate', '--manifest', $candidate, '--disable-interactivity') -Log "$OutputDirectory/schema.log"
        Invoke-WindowsChannelCommand -FilePath $Winget -Arguments @('settings', '--enable', 'LocalManifestFiles') -Log "$OutputDirectory/settings.log"
        $install = @('install', '--manifest', $candidate, '--architecture', $Architecture, '--installer-type', $InstallerType, '--silent', '--accept-package-agreements', '--accept-source-agreements', '--disable-interactivity')
        if ($InstallerType -eq 'zip') {
            $install += '--scope', 'user'
        }
        $ownsInstall = $true
        Invoke-WindowsChannelCommand -FilePath $Winget -Arguments $install -Log "$OutputDirectory/install.log"
        $installed = if ($InstallerType -eq 'zip') { "$env:LOCALAPPDATA/Microsoft/WinGet/Links/grate.exe" } else { "$env:LOCALAPPDATA/erikbra/grate/grate.exe" }
        Test-WindowsChannelExecutable -Executable $installed -ExpectedExecutable $expected -Distribution $Distribution -Version $Version -OutputDirectory $OutputDirectory
        $uninstall = @('uninstall', '--manifest', $candidate, '--silent', '--disable-interactivity')
        if ($InstallerType -eq 'zip') {
            $arp = 'HKCU:/Software/Microsoft/Windows/CurrentVersion/Uninstall'
            $entries = @(Get-ItemProperty "$arp/*" | Where-Object { $_.WinGetPackageIdentifier -ceq $packageId -and $_.DisplayVersion -ceq $Version })
            if ($entries.Count -ne 1) {
                throw 'Expected exactly one local portable registration.'
            }
            $uninstall = @('uninstall', '--product-code', $entries[0].PSChildName, '--silent', '--disable-interactivity')
        }
        Invoke-WindowsChannelCommand -FilePath $Winget -Arguments $uninstall -Log "$OutputDirectory/uninstall.log"
        if (Test-Path -LiteralPath $installed) {
            throw 'WinGet uninstall left the release executable.'
        }
        $ownsInstall = $false
    } else {
        if ($Architecture -cne 'x64' -or (Get-Command grate -ErrorAction SilentlyContinue)) {
            throw 'Chocolatey verification requires an isolated x64 runner.'
        }
        $packages = @(Get-ChildItem -LiteralPath $CandidateDirectory -Filter '*.nupkg' -File -Recurse)
        if ($packages.Count -ne 1 -or $packages[0].Name -cne "$id.$Version.nupkg") {
            throw 'Expected exactly the original profile Chocolatey package.'
        }
        $package = $packages[0]
        $packageHash = (Get-FileHash -LiteralPath $package.FullName -Algorithm SHA256).Hash
        $unpacked = "$OutputDirectory/unpacked"
        [IO.Compression.ZipFile]::ExtractToDirectory($package.FullName, $unpacked)
        [xml]$nuspec = Get-Content -LiteralPath "$unpacked/$id.nuspec" -Raw
        if ($nuspec.package.metadata.id -cne $id -or $nuspec.package.metadata.version -cne $Version -or
            (Get-FileHash -LiteralPath "$unpacked/tools/grate.exe" -Algorithm SHA256).Hash -cne (Get-FileHash -LiteralPath $expected -Algorithm SHA256).Hash) {
            throw 'Chocolatey package identity or embedded public payload differs.'
        }
        $choco = (Get-Command choco.exe).Source
        $ownsInstall = $true
        Invoke-WindowsChannelCommand -FilePath $choco -Arguments @('install', $id, "--version=$Version", "--source=$($package.DirectoryName)", '--yes', '--no-progress', '--limit-output') -Log "$OutputDirectory/install.log"
        $installed = Join-Path $env:ChocolateyInstall "lib/$id/tools/grate.exe"
        Test-WindowsChannelExecutable -Executable $installed -ExpectedExecutable $expected -Distribution $Distribution -Version $Version -OutputDirectory $OutputDirectory
        Invoke-WindowsChannelCommand -FilePath (Join-Path $env:ChocolateyInstall 'bin/grate.exe') -Arguments @('--help') -Log "$OutputDirectory/shim-help.log"
        Invoke-WindowsChannelCommand -FilePath $choco -Arguments @('uninstall', $id, '--yes', '--no-progress', '--limit-output') -Log "$OutputDirectory/uninstall.log"
        if ((Test-Path -LiteralPath $installed) -or (Test-Path -LiteralPath (Join-Path $env:ChocolateyInstall 'bin/grate.exe'))) {
            throw 'Chocolatey uninstall left the executable or command shim.'
        }
        $ownsInstall = $false
    }
    [pscustomobject]@{
        Version = $Version
        ReleaseRunId = $ReleaseRunId
        ValidationRunId = [string]$env:GITHUB_RUN_ID
        SourceCommit = $context.SourceCommit
        Distribution = $Distribution
        PackageId = $id
        WingetPackageIdentifier = if ($Channel -eq 'winget') { $packageId } else { $null }
        Channel = $Channel
        Architecture = $Architecture
        InstallerType = $InstallerType
        PackageSha256 = $packageHash
        ManifestHashes = $manifestHashes
        LegacyMigration = $legacyMigration
        PublicExecutableSha256 = (Get-FileHash -LiteralPath $expected -Algorithm SHA256).Hash
        MigrationAndRerun = if ($Distribution -in @('All', 'SQLite')) { 'passed; SQLite 3.53.4 and one history row' } else { 'not applicable; help and skill smoke only' }
        Status = 'passed'
    } | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath "$OutputDirectory/verification.json" -Encoding utf8NoBOM
} finally {
    if ($ownsInstall) {
        Write-Warning 'Verification failed while an installation was owned by this disposable runner; no passing record is emitted.'
    }
}
