# WinGet helpers

These scripts support manifest preparation and verification. Paths are resolved
from the scripts so callers can run from any working directory.

| File | Purpose |
| --- | --- |
| `MigrationManifestPolicy.ps1` | Dot-sourced policy for validating MSI identity and converting wingetcreate's supported YAML shape into new-ID manifests. Rejects unexpected shapes or mismatched payload metadata. |
| `Initialize-LifecycleRunner.ps1` | Downloads, verifies and installs the pinned WinGet client and dependencies on a disposable GitHub-hosted Windows runner. Used for release schema checks and lifecycle jobs; returns the client path. |

Production preparation starts at [Create-Installer.ps1](../Create-Installer.ps1).
The policy is also exercised by the tests in [tests/](../tests/).
