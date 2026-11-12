# MSI verification

| File | Purpose |
| --- | --- |
| `Test-InstallerAuthoring.Tests.ps1` | Accepts the real WiX template and rejects mutations of its cleanup, identity, scope and upgrade contract. |
| `Test-InstallerIdentity.Tests.ps1` | Checks independent UUID examples, architecture families and invalid stable/prerelease versions. |
| `Test-InstallerMetadata.Tests.ps1` | Checks an actual built MSI's metadata and rejects an invalid MSI database; requires Windows. |
| `Test-WinGetMsiLifecycle.Assertions.Tests.ps1` | Tests lifecycle assertions against correct and deliberately incorrect fixture state. |
| `WinGetMsiLifecycle.Assertions.ps1` | Shared assertions for native registration, payload, identity and external data. |
| `Test-MsiLifecycleSupervisor.Tests.ps1` | Checks successful and timed-out child-worker handling on Windows. |
| `Test-WinGetMsiLifecycle.ps1` | Exercises native installation, upgrade, rollback, identity and uninstall using candidate MSI files on disposable Windows runners. |
| `Test-PrereleaseMsiPolicy.ps1` | Builds isolated probe packages and verifies same-core refusals, explicit replacement and higher-core upgrades on a disposable native Windows runner. |
| [support/](support/README.md) | Native inventory workers and the bounded lifecycle supervisor. |

Portable policy checks can run from the repository root with PowerShell:

```powershell
./installers/msi/tests/Test-InstallerAuthoring.Tests.ps1
./installers/msi/tests/Test-InstallerIdentity.Tests.ps1
./installers/msi/tests/Test-WinGetMsiLifecycle.Assertions.Tests.ps1
```

Native checks are selected by the MSI/WinGet workflows. They modify installation
state and require their disposable Windows-runner guards. Keep their logs and
reports in CI artifacts or temporary directories, outside git.
