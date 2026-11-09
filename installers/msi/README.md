# Windows MSI installer

`Create-Installer.ps1` packages a published `grate.exe` as a per-user x64 or
ARM64 MSI. It validates the executable's version and installer authoring, derives
the product identity, builds the native upgrade action, and compiles the WiX
template. Building requires Windows and Visual Studio C++ tools; the script
downloads and verifies the pinned WiX archive.

From the repository root:

```powershell
./installers/msi/Create-Installer.ps1 -grateExe <published-grate.exe> -Version <numeric-version> -ReleaseVersion <full-semver> -arch x64
```

The MSI is written to `tmp/grate-<numeric-version>.msi`; `wix/` contains downloaded
build tools. These are generated output, not source.

| File or folder | Purpose |
| --- | --- |
| `Create-Installer.ps1` | Build entrypoint; checks the payload and assembles the package. |
| `grate.wxs` | WiX template for the per-user installation, PATH entry and transactional upgrade. |
| `identity-contract.json` | Stable identity namespace, architecture families and legacy product identity. |
| `InstallerLifecycle.Process.ps1` | Bounded lifecycle subprocesses, output draining and command evidence. |
| [helpers/](helpers/README.md) | Version/identity calculation, read-only metadata readers and authoring validation. |
| [native/](native/README.md) | C++ custom action and its Windows build script. |
| [tests/](tests/README.md) | Policy, metadata, assertion and native lifecycle checks. |

Full SemVer distinguishes ProductCodes, while MSI ordering uses the numeric
version. Same-core prerelease/final replacements require explicit uninstall and
reinstall. See the [WinGet migration contract](../winget/MIGRATION.md) for upgrade
and package-identity behavior.

CI runs `Test-InstallerLifecycle.ps1` through the existing lifecycle supervisor
with a six-minute limit and retains both lifecycle and supervisor artifacts.
This also bounds COM calls outside individual subprocesses. Run the portable
process regressions with `pwsh -NoProfile -File installers/msi/Test-InstallerLifecycle.Process.Tests.ps1`.
