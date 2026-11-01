# Debian package lifecycle verification

Build two packages with `Create-Package.ps1` from the candidate standalone binary,
copying the first package aside before the recipe recreates its staging folder.
For example, use package versions `0.0.1-1` and `0.0.2-1` (`-version 0.0.1` and
`-version 0.0.2` in the recipe). Both packages may contain identical binary bytes:
this checks the package upgrade transaction and installed payload, not a change
to the executable's embedded application version.

Run on a matching native Docker engine:

```sh
bash installers/deb/Test-PackageLifecycle.sh \
  /absolute/path/grate_0.0.1-1_arm64.deb \
  /absolute/path/grate_0.0.2-1_arm64.deb \
  arm64 0.0.1-1 0.0.2-1 /absolute/path/diagnostics
```

Use `amd64` on the x64 CI runner. The wrapper rejects a different Docker engine
architecture, runs an isolated Ubuntu container with an eight-minute execution
limit, and removes only its own container. Package installation never runs on
the host. `Verify-PackageLifecycle.sh` is container-side implementation and
refuses direct execution on the host.

The test installs package dependencies, checks dpkg registration, architecture,
version and payload, runs help and bundled-skill installation, and inspects real
SQLite data/history after migrations and reruns. It then upgrades, applies a new
migration using the same database, removes/purges the package, and checks that
package-owned files are gone while the database and installed skill remain.

Retain the diagnostics directory as a CI artifact even on failure. It contains
the complete container/apt/application log, final package inventory and the
disposable migration database when available. No generated package is published.
