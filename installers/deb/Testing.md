# Debian package lifecycle verification

Build two packages with `Create-Package.ps1` from the candidate standalone binary,
copying the first package aside before the recipe recreates its staging folder.
For example, use package versions `0.0.1-1` and `0.0.2-1` (`-version 0.0.1` and
`-version 0.0.2` in the recipe). Both packages may contain identical binary bytes:
this checks the package upgrade transaction and installed payload, not a change
to the executable's embedded application version.

Run on a matching native Docker engine:

```powershell
./installers/deb/Test-PackageLifecycle.ps1 `
  -InitialPackage /absolute/path/grate_0.0.1-1_arm64.deb `
  -UpgradePackage /absolute/path/grate_0.0.2-1_arm64.deb `
  -Architecture arm64 -InitialVersion 0.0.1-1 -UpgradeVersion 0.0.2-1 `
  -OutputDirectory /absolute/path/diagnostics
```

Use PowerShell 7 and `amd64` on the x64 CI runner. The host-side PowerShell wrapper
rejects a different Docker engine architecture and starts a uniquely named,
ownership-labeled Ubuntu container. `Verify-PackageLifecycle.ps1` runs on the host
and executes all package, application and SQLite commands through bounded
`docker exec` calls. The container needs no PowerShell installation. The verifier
checks ownership before executing any commands; package installation never runs
on the host.

The verifier has an eight-minute work deadline. The container has a ten-minute
watchdog so failure diagnostics have time to finish, and the wrapper supervises
the verifier process for at most ten minutes. The wrapper removes only its own
container on success, failure or timeout.

The test installs package dependencies, checks dpkg registration, architecture,
version and payload, runs help and bundled-skill installation, and inspects real
SQLite data/history after migrations and reruns. It then upgrades, applies a new
migration using the same database, removes/purges the package, and checks that
package-owned files are gone while the database and installed skill remain.

Retain the diagnostics directory as a CI artifact even on failure. It contains
the complete container/apt/application log, final package inventory and the
disposable migration database when available. No generated package is published.

Run the focused orchestration and assertion checks without installing packages:

```powershell
pwsh -NoProfile -File installers/deb/Test-PackageLifecycle.Tests.ps1
```

These use a simulated Docker boundary to check lifecycle assertions, failure
diagnostics, ownership, native architecture and cleanup. They complement the real
package lifecycle command above; they do not prove actual dpkg/SQLite behavior.
