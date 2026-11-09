# Linux x64 database-specific distribution PoC

The checkout builds the same CLI project as `All`, `SQLite`, `SQLServer`,
`MariaDB`, `PostgreSQL` and `Oracle` using `GrateDistribution`. The NuGet tool
IDs are `grate`, `grate-sqlite`, `grate-sqlserver`, `grate-mariadb`,
`grate-postgresql` and `grate-oracle`. Every package exposes the command `grate`.

The original comparison scripts below cover All, SQLite, SQL Server and MariaDB
and install each tool into a separate directory. PostgreSQL and Oracle use the
same build and command contract. Their packaged CLI checks belong to the
per-provider CI validation alongside the other database providers.

## Validate a distribution against its database

With the SDK from `global.json` and Docker available, run, for example:

```powershell
pwsh -NoProfile -File scripts/ci/Invoke-DistributionTests.ps1 -Distribution PostgreSQL -Database PostgreSQL -OutputDirectory /tmp/grate-postgresql-check
```

Use a fresh absolute output directory. The default RID is `linux-x64`; use
`-RuntimeIdentifier linux-arm64` on a native Linux Arm64 host. Server suites start
disposable database containers; SQLite uses local files. The script publishes a
self-contained CLI, packs the tool for all four supported frameworks, checks
provider/client inclusion and exclusion, and installs that exact tool from a
local-only feed with an isolated cache. It runs the complete matching
`CommandLine.<Database>` suite against each form on `net11.0`. Existing
CLI-specific skips remain visible in the reports; library-only tests that require
in-process migration internals are covered by the separate provider suites.

PR CI requires both `All` and the matching slim profile for `Sqlite`, `SqlServer`,
`SqlServerCaseSensitive`, `PostgreSQL`, `MariaDB` and `Oracle`. The case-sensitive
suite uses the `SQLServer` profile. The integration workflow also tests both
variants against each configured database image/version. Neither lane treats a
failing migration suite as optional. Current release publishing still uses the
all-in-one identity; these checks produce candidate artifacts without publishing
new packages to public feeds.

## Run the comparison

From the repository root, with PowerShell 7 and Docker available, run the wrapper.
Choose a fresh repository-relative directory for its artifacts.

```powershell
pwsh docs/design/slim-distributions-poc/run.ps1 -OutputDirectory artifacts/slim-poc -Mode cli
```

The wrapper starts disposable SQL Server 2022 and MariaDB 10.4 containers on a
dedicated network, waits for both servers, and runs the builds and checks in a
Linux x64 SDK container. It generates a temporary database password and removes
its containers and network when the run ends. On Apple Silicon the CLI and SQL
Server containers use x64 emulation.

To use an existing disposable test environment, run `verify.py` on Linux x64
with Python 3 and the SDK pinned in `global.json`. Supply
`GRATE_POC_SQLSERVER` and `GRATE_POC_MARIADB` connection strings containing
a literal `{database}` placeholder. The script substitutes unique database
names per package and invocation. The test account needs database creation rights.

```sh
python3 docs/design/slim-distributions-poc/verify.py --output "$PWD/artifacts/slim-poc"
```

## Docker and Debian comparison

Run the packaging mode from the repository root with PowerShell 7, Python 3.9+, Docker and
a fresh output directory.

```powershell
pwsh docs/design/slim-distributions-poc/run.ps1 -OutputDirectory artifacts/slim-packaging -Mode packaging
```

This builds local Linux amd64 images using the real Alpine Dockerfile and .deb
packages using the existing Debian recipe, for All, SQLite, SQLServer and
MariaDB. It runs Docker migrations through the normal entrypoint and Debian
migrations through the installed `/usr/bin/grate`. Each migration is rerun and
its data/history is queried by the same independent database checker used by
the CLI PoC. The test also exercises package conflicts and purge behavior.

The CLI build uses the pinned .NET 11 SDK. Debian archive assembly uses a native
Linux packaging container, with the payload architecture explicitly set to
amd64. The installed packages and Docker images execute as Linux amd64, using
emulation on Apple Silicon.

Record Docker's reported image size separately from the compressed `docker save`
archive and the .deb size. The gzip image archive is a local transfer artifact.
Registry transfer size depends on registry layer compression and which layers
the client already has. Keep all measured sizes and reductions
in the PR record, with MB used for the human-readable tables.

## What it checks

- Build each standalone Linux x64 binary with the existing `net11.0`
  single-file and trimming settings, ZIP it, extract it and run the result.
- Pack every .NET tool with `net8.0`, `net9.0`, `net10.0` and `net11.0`
  assets. Check that all four declare the command `grate`, install from a
  local-only feed with an isolated cache, and compare installed package bytes.
  Tool execution uses `net11.0`.
- Migrate and rerun against the selected database with each packaged form.
  For `All`, exercise SQLite, SQL Server and MariaDB. For each slim build,
  exercise its default and explicit provider selection. A separate direct-client
  program queries the data, script hashes/history and migration error table
  after each invocation.
- Reject an unsupported provider before a migration starts, check help, and
  install the bundled skill through every executable.
- Inspect each dependency manifest to require the selected providers and client
  libraries and exclude the other providers and clients from the slim builds.
- Compare executable, ZIP and NuGet package bytes with matching versions, SDK,
  frameworks and compression settings. Each build form has its own output root.

`results.json` records measurements and savings against `All`. Each variant
directory contains its ZIP, NuGet package, build logs, installed tool and
migration/query logs. SQLite files stay in the output directory. SQL Server and
MariaDB test data live in the disposable containers during verification.

Keep point-in-time outputs in local artifacts or the PR verification record.
The proposal covers the larger release discussion.
[Distribution proposal](../database-specific-distributions.md)
