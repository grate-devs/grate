# WinGet verification

Preparation tests use synthetic release/installer data; lifecycle tests install
real packages on disposable Windows CI runners. Run the portable policy checks
with PowerShell 7 from the repository root:

```powershell
./installers/winget/tests/Test-CreateInstaller.Tests.ps1
./installers/winget/tests/Test-InstallerCorrelation.Tests.ps1
./installers/winget/tests/Test-LifecycleCatalog.Tests.ps1
./installers/winget/tests/Test-WinGetSourceCorrelation.Assertions.Tests.ps1
```

| File or folder | Purpose |
| --- | --- |
| `Test-CreateInstaller.Tests.ps1` | Exercises manifest generation and rejection paths with mocked release metadata, MSI inspection and external tools. |
| `Test-InstallerCorrelation.ps1` | Checks one generated installer manifest against expected URL, hashes, architecture and identity. |
| `Test-InstallerCorrelation.Tests.ps1` | Proves correlation checks reject incorrect identities, hashes and YAML fields. |
| `Test-LifecycleCatalog.Tests.ps1` | Checks old/new-ID catalogs and diagnostic bridge selection. |
| `Test-MigrationManifestPreparation.ps1` | Validates local candidate MSI/ZIP hashes and metadata, prepares new-ID manifests, and optionally runs WinGet schema validation. |
| `Test-ReleasePreparation.ps1` | Windows check against a fixed historical published release; verifies normal preparation and rejection of an unsupported identity transition. |
| `Test-WinGetLifecycle.ps1` | Windows installation, identity transition, upgrade, query/export, data preservation and uninstall checks. |
| `WinGetSourceCorrelation.Assertions.ps1` | Shared assertions for installed IDs, source registration and export correlation. |
| `Test-WinGetSourceCorrelation.Assertions.Tests.ps1` | Exercises those assertions with valid and deliberately incorrect results. |
| `support/` | Verified lifecycle asset inventory and source-catalog construction. |
| `source/` | Disposable REST/pre-indexed sources and their protocol tests. |

Use the workflows and prerequisites in [MIGRATION.md](../MIGRATION.md) for real
Windows execution. Store inventories, logs and generated candidates in temporary
directories or CI artifacts, outside git.
