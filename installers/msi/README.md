# Windows MSI installer

`Create-Installer.ps1` packages a published `grate.exe` as a per-user x64 or
ARM64 MSI. It validates the executable's version and installer authoring, derives
the product identity, builds the native upgrade action, and compiles the WiX
template. Building requires Windows and Visual Studio C++ tools; the script
downloads and verifies the pinned WiX archive.

From the repository root:

```powershell
./installers/msi/Create-Installer.ps1 -grateExe <published-grate.exe> -Version <numeric-version> -ReleaseVersion <full-semver> -arch x64
./installers/msi/Create-Installer.ps1 -grateExe <published-sqlite-grate.exe> -Version <numeric-version> -ReleaseVersion <full-semver> -arch arm64 -Distribution SQLite
```

`-Distribution` accepts `All` (the default), `SQLite`, `SQLServer`, `MariaDB`,
`PostgreSQL` and `Oracle`. The payload's Windows product name and full release
must match the selected profile, including when cross-building an ARM64 MSI.
Output is `tmp/grate-<numeric-version>.msi` for All and
`tmp/grate-<profile>-<numeric-version>.msi` for slim profiles, using lowercase
profile names. `wix/` contains downloaded build tools. These are generated output.

Every profile installs the `grate.exe` command in the existing per-user
`LocalAppData/erikbra/grate` directory. Profiles cannot coexist there. The native
ownership check refuses another profile or architecture before installation
changes files, registration or PATH. Switching requires explicitly uninstalling
the existing profile. Each profile/architecture has a stable upgrade family;
future releases upgrade within that family. All retains its published identities,
components and registry key, and alone supports the legacy All upgrade bridge.

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

CI runs `Test-InstallerLifecycle.ps1` for each profile on native Windows x64 and
ARM64 through the existing lifecycle supervisor with a ten-minute limit. It
checks exact installed payloads, refused cross-profile switching, major upgrades,
bundled skills, external data preservation and uninstall. All and SQLite run
SQLite migrations and reruns. Server profiles check help, their compiled default
and unsupported-provider rejection; their actual migrations run in the matching
Linux CLI suites. Both lifecycle and supervisor artifacts are retained.
This also bounds COM calls outside individual subprocesses. Run the portable
process regressions with `pwsh -NoProfile -File installers/msi/Test-InstallerLifecycle.Process.Tests.ps1`.
