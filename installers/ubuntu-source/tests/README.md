# Installed MariaDB package verification

The builder and [source recipe](../README.md) produce two local self-contained
packages with different Debian versions, for example `0.0.1` and `0.0.2`. Native
libraries are provisioned before the test; package installation and migration
then run on an internal Docker network without external network access.

```powershell
docker build --platform linux/arm64 -f installers/ubuntu-source/tests/Runtime.Dockerfile `
    -t grate-ubuntu-package-test:26.04 .
if ($LASTEXITCODE -ne 0) { throw 'Runtime fixture provisioning failed.' }
docker pull --platform linux/arm64 mariadb:10.4
if ($LASTEXITCODE -ne 0) { throw 'Database fixture provisioning failed.' }
pwsh -NoProfile -File installers/ubuntu-source/tests/Test-MariaDbPackage.ps1 `
    -InitialPackage /absolute/path/grate-mariadb_0.0.1-1~poc1_arm64.deb `
    -UpgradePackage /absolute/path/grate-mariadb_0.0.2-1~poc1_arm64.deb `
    -OutputDirectory /absolute/path/new-package-evidence
```

The runtime fixture contains no SDK, shared .NET runtime, PowerShell or NuGet
cache. The verifier checks this and records its package inventory. It installs
through dpkg, verifies candidate/installed bytes, compiled-provider validation,
help/defaults, bundled skill contents and installed notice/manifest files.
The fixture removes Ubuntu Docker's doc/man exclusion policy before installing
grate so these installed files are checked. Native libraries include Brotli and
LTTng. This package targets Ubuntu 26.04's libc 2.43 baseline, not older releases.

The installed command performs real MariaDB migrations, followed by independent
MariaDB CLI queries of literal row values, persisted script hashes, error counts
and exact script-to-version relationships. A rerun must preserve those values.
An upgrade installs the newer Debian version and applies a new script against
the same database. Variant switching uses an explicitly labeled metadata-only
grate-sqlite fixture to exercise conflicts and shared-command ownership; it does
not verify SQLite functionality or a real second provider distribution.

Remove/switch/reinstall/purge must preserve external database history, user SQL,
skill installations and user output. An ELF dependency check examines the
installed executable and any extracted native libraries. This singlefile host
can include native runtime components without separate `.so` files. Owned
containers, anonymous database volumes and network are
removed in a finally block; evidence is retained even when an assertion fails.
Disposable credentials are redacted from command output.

This verifies the selected package, architecture, MariaDB fixture and migration
paths. It does not cover all server/authentication/TLS/plugin scenarios or grant
Ubuntu archive acceptance. Record native versus emulated execution and do not
extend arm64 results to amd64. The original global .NET 8/9/11 targets and other
providers are outside this net10 MariaDB package experiment.
