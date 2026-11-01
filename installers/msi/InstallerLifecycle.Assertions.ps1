function Assert-MsiRegistration {
    param([int]$State, [string]$Version, [int]$AssignmentType, [string]$ExpectedVersion)
    if ($State -ne 5) { throw "Expected installed MSI product state 5, got $State." }
    if ($Version -ne $ExpectedVersion) { throw "Expected registered MSI version $ExpectedVersion, got $Version." }
    if ($AssignmentType -ne 0) { throw "Expected a per-user MSI registration, got assignment type $AssignmentType." }
}

function Assert-MsiPayload {
    param([string]$InstalledExecutable, [string]$ExpectedExecutable)
    if (!(Test-Path -LiteralPath $InstalledExecutable -PathType Leaf)) { throw "Installed executable is missing: $InstalledExecutable" }
    $installedHash = (Get-FileHash -LiteralPath $InstalledExecutable -Algorithm SHA256).Hash
    $expectedHash = (Get-FileHash -LiteralPath $ExpectedExecutable -Algorithm SHA256).Hash
    if ($installedHash -ne $expectedHash) { throw 'The installed executable does not match the expected package payload.' }
}

function Assert-MsiUninstalled {
    param([int]$State, [string]$InstallDirectory, [bool]$MarkerPresent)
    if ($State -ne -1) { throw "MSI product remains registered after uninstall: state $State." }
    if (Test-Path -LiteralPath $InstallDirectory) { throw "Installation directory remains after uninstall: $InstallDirectory" }
    if ($MarkerPresent) { throw 'The per-user installed registry marker remains after uninstall.' }
}

function Assert-MsiDataPreserved {
    param([string]$Path, [string]$ExpectedHash)
    if (!(Test-Path -LiteralPath $Path -PathType Leaf)) { throw "User data was removed: $Path" }
    if ((Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash -ne $ExpectedHash) {
        throw "User data changed during package installation/removal: $Path"
    }
}

function Get-MsiUpgradeVersion {
    param([version]$PackageVersion, [version]$PayloadVersion)
    # Windows Installer compares three numeric fields. Ensure the second payload is
    # newer too, so the ordinary 'o' reinstall mode must actually replace it.
    $baseline = @($PackageVersion, $PayloadVersion) | Sort-Object -Descending | Select-Object -First 1
    if ($baseline.Major -gt 255 -or $baseline.Minor -gt 255 -or $baseline.Build -ge 65535) {
        throw "Cannot derive a disposable MSI upgrade version from $baseline."
    }
    return "$($baseline.Major).$($baseline.Minor).$($baseline.Build + 1)"
}

function Copy-MsiLifecycleSource {
    param([string]$MsiPath, [string]$Directory)
    New-Item -ItemType Directory -Force $Directory | Out-Null
    # Install from retained sources, not Create-Installer's disposable tmp tree.
    # Both minor-update sources use the same package basename while retaining
    # separate immutable files for Windows Installer's source resolution.
    $staged = Join-Path $Directory 'grate.msi'
    Copy-Item -LiteralPath $MsiPath -Destination $staged
    return $staged
}
