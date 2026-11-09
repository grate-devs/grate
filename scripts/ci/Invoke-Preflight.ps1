#!/usr/bin/env pwsh
# Run from the repository root, locally or through the shared preflight action.
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true

./scripts/release/Install-TestDependencies.ps1
# The existing runner isolates each suite's PowerShell state and exit status.
./scripts/release/Run-Tests.ps1 -Path scripts -Filter Test-CiPolicy.Tests.ps1
./scripts/release/Run-Tests.ps1 -Path scripts/ci -Filter Test-*.ps1
./scripts/release/Run-Tests.ps1 -Path .github/scripts -Filter monitor-test-containers.Tests.ps1
./scripts/release/Run-Tests.ps1
./scripts/release/Run-Tests.ps1 -Path installers/docker/tests
./scripts/release/Run-Tests.ps1 -Path installers/deb -Filter Test-PackageLifecycle.Tests.ps1
./scripts/release/Run-Tests.ps1 -Path installers/homebrew -Filter Test-*.ps1
./scripts/release/Run-Tests.ps1 -Path installers/chocolatey -Filter Test-*.ps1
./scripts/release/Run-Tests.ps1 -Path installers/msi/tests -Filter Test-InstallerIdentity.Tests.ps1
./scripts/release/Run-Tests.ps1 -Path installers/msi/tests -Filter Test-InstallerAuthoring.Tests.ps1
./scripts/release/Run-Tests.ps1 -Path installers/winget/tests -Filter Test-CreateInstaller.Tests.ps1
./scripts/release/Run-Tests.ps1 -Path installers/winget/tests -Filter Test-InstallerCorrelation.Tests.ps1

$tokens = $null
$errors = $null
$null = [Management.Automation.Language.Parser]::ParseFile("$PWD/build-docker-local.ps1", [ref]$tokens, [ref]$errors)
if ($errors.Count -gt 0) {
    throw ($errors.Message -join [Environment]::NewLine)
}
