# Pre-indexed source fixture

These files implement the SQLite source option used by the disposable Windows
lifecycle checks. [Start-PreIndexedSource.ps1](../Start-PreIndexedSource.ps1)
coordinates index creation and HTTPS hosting.

| File | Purpose |
| --- | --- |
| `New-SingletonManifests.ps1` | Converts the fixture catalog into standalone manifests for index construction. |
| `Test-SingletonManifests.Tests.ps1` | Checks conversion, old/new identity selection and duplicate rejection. |
| `WinGetIndex.cs` | Calls the pinned WinGet index APIs to build the SQLite package index. |
| `server.ps1` | Serves the generated source package and fixture assets through loopback HTTPS. |
| `test_server.ps1` | Checks source-package responses, assets and path isolation. |

Run the PowerShell checks from the repository root:

```powershell
pwsh -NoProfile -File installers/winget/tests/source/preindexed/test_server.ps1
```

Windows source registration and installation remain part of the real lifecycle
workflow, not these protocol checks.
