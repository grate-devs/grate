# MSI helpers

These scripts support the build entrypoint and WinGet preparation. Paths are
resolved from the script directory, so callers can use any working directory.

| File | Purpose |
| --- | --- |
| `Get-InstallerIdentity.ps1` | Validates numeric/full versions and derives reproducible profile/architecture ProductCodes, stable UpgradeCodes and component identities from `../identity-contract.json`. |
| `InstallerPayloadPolicy.ps1` | Rejects payload version or Windows product-name mismatches before building an MSI. |
| `Get-InstallerMetadata.ps1` | Reads MSI properties and platform metadata without installing or changing the package; requires Windows Installer. |
| `Get-InstallerMetadataBatch.ps1` | Reads a JSON list of MSI paths in a separate metadata worker and writes its results. |
| `Test-InstallerAuthoring.ps1` | Production build guard for the WiX template's identity, per-user paths, cleanup and transactional upgrade sequence. |

Metadata inspection does not prove installation or upgrade behavior; the native
checks in [../tests/](../tests/README.md) cover those boundaries.
