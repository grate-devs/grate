# Database-specific distributions

Choose `All`, `SQLite`, `SQLServer`, `MariaDB`, `PostgreSQL` or `Oracle` with
the MSBuild property `GrateDistribution`. Every variant exposes the command
`grate`. Omitting the property keeps the existing all-in-one distribution.

| Profile | NuGet tool ID | Default database |
| --- | --- | --- |
| All | `grate` | SQL Server |
| SQLite | `grate-sqlite` | SQLite |
| SQLServer | `grate-sqlserver` | SQL Server |
| MariaDB | `grate-mariadb` | MariaDB |
| PostgreSQL | `grate-postgresql` | PostgreSQL |
| Oracle | `grate-oracle` | Oracle |

Every profile is built for the existing standalone platform matrix:
`win-x64`, `win-x86`, `win-arm64`, `linux-x64`, `linux-arm64`,
`linux-musl-x64`, `linux-musl-arm64`, `osx-x64` and `osx-arm64`.
NuGet tools include net8.0, net9.0, net10.0 and net11.0 assets.
Debian packages cover amd64/arm64; Docker images cover linux/amd64 and linux/arm64.
The all-in-one package and asset names remain unchanged.

The generated [distribution catalog](distribution-catalog.md) lists every
package/platform permutation, release filename and package-manager identity,
with links to build results and workflow status badges.

Every profile also has Windows x64/Arm64 MSI installers, a WinGet candidate,
a Windows x64 Chocolatey package, a macOS Intel/Arm64 Homebrew cask and a
source-built Homebrew formula candidate. These changes are available in this
checkout; new package-manager identities require their channel's publication
or acceptance before users can install them from public sources.

| Channel | All identity | SQLite example |
| --- | --- | --- |
| CLI ZIP, MSI, Debian, Chocolatey, Homebrew | `grate` | `grate-sqlite` |
| WinGet | `grate-devs.grate` | `grate-devs.grate.SQLite` |
| Docker tags | `<version>`, `latest` | `sqlite-<version>`, `sqlite` |

The other profile suffixes are `sqlserver`, `mariadb`, `postgresql` and `oracle`;
WinGet uses the profile's exact casing from the table above. Package-manager
variants share the `grate` command: uninstall the installed variant before
switching. MSI families and package conflict checks protect that command;
Homebrew also rejects an existing linked binary during a cross-format switch.

The release workflow retains all six Chocolatey packages without submitting
them, prepares all six WinGet candidates after stable GitHub publication,
updates all six casks in the existing tap and retains six source-formula
candidates. Formula submission and Chocolatey/WinGet acceptance remain separate
release steps. See the [release runbook](ReleaseProcess.md).

## Optional NativeAOT archives

This checkout adds a NativeAOT ZIP alongside each ordinary CLI ZIP, for all six
profiles and all nine platforms above. For example,
`grate-postgresql-linux-x64-nativeaot-<version>.zip` accompanies
`grate-postgresql-linux-x64-self-contained-<version>.zip`. The optional archives
become available when a release containing this change is published.
NuGet tools/libraries, MSI, Debian, Docker and package-manager channels continue
to use their existing builds and identities.

NativeAOT compiles the CLI ahead of time with full assembly trimming and
Dapper.AOT-generated database calls. It needs no installed .NET runtime.
Extract the **complete** ZIP into its own directory: SQLite and All include a
native SQLite library beside `grate`. Linux glibc and musl archives are separate;
choose the matching operating system and architecture. Native OS dependencies
such as ICU and OpenSSL still apply. NativeAOT can improve startup and memory
use; file-size savings depend on the database profile.

Linux glibc release archives are built on Ubuntu 24.04; musl archives use Alpine
3.24. These are the build/test baselines. A matching RID alone does not establish
compatibility with older distributions: NativeAOT links against the build OS's
native libraries. Use an ordinary archive where an older Linux baseline is needed.

Build and smoke-test an archive with PowerShell 7, the pinned SDK and the
[NativeAOT prerequisites](https://learn.microsoft.com/dotnet/core/deploying/native-aot/):

```powershell
./scripts/release/Publish-NativeAot.ps1 -Distribution PostgreSQL `
    -RuntimeIdentifier linux-x64 -Version 0.0.1 `
    -OutputDirectory ./artifacts/native-postgresql
```

Use a fresh output directory and build on the target OS; Linux/macOS Arm64 also
require a matching host architecture. For musl on Linux, build the pinned Alpine
toolchain and pass its immutable image ID as `-ContainerImage`:

```powershell
docker build --file scripts/release/NativeAot.Alpine.Dockerfile --tag grate-aot-toolchain .
$image = docker image inspect grate-aot-toolchain --format '{{.Id}}'
./scripts/release/Publish-NativeAot.ps1 -Distribution SQLite `
    -RuntimeIdentifier linux-musl-arm64 -Version 0.0.1 `
    -ContainerImage $image -OutputDirectory ./artifacts/native-sqlite-musl
```

The publisher retains expanded trim/AOT diagnostics and compiler/runtime-pack
evidence, checks provider selection, verifies every archived file by hash, and
executes the unpacked CLI. All/SQLite also migrate and rerun a SQLite database.
The release workflow runs the existing database command-line suites against the
actual Linux x64 release ZIPs for All and each matching provider, including
case-sensitive SQL Server. Native-host smoke checks cover the other platforms;
the full database suite is not repeated for every OS/architecture.

To exercise a local archive against a server database, add `-NativeAot` and
`-NativeAotArchive <zip>` to the verification command below. The test runner
remains a normal .NET build; NativeAOT applies to the CLI being tested.

## Validate a profile against its database

Install PowerShell 7, Docker and the SDK pinned in `global.json`, then run from
the repository root with a fresh output directory:

```powershell
pwsh -NoProfile -File scripts/ci/Invoke-DistributionTests.ps1 -Distribution PostgreSQL -Database PostgreSQL -OutputDirectory /tmp/grate-postgresql-check
```

The default RID is `linux-x64`. Select the native RID with
`-RuntimeIdentifier linux-arm64` on Linux Arm64. Server suites start disposable
database containers; SQLite uses local files. Test image overrides and isolated
external-database configuration follow the [test and artifact map](agents/testing.md).

The runner publishes a self-contained CLI, packs all four tool frameworks,
checks selected/omitted providers and clients, and installs that exact tool
from a local-only feed with an isolated cache. It runs the complete matching
`CommandLine.<Database>` suite against both forms on net11.0. It also checks
help, unsupported-provider rejection and bundled skill installation.
The case-sensitive SQL Server suite uses the SQLServer distribution and the
SqlServerCaseSensitive database category, and checks the actual database collation.

PR CI requires both All and the matching slim profile for all six database
categories. Provider-library tests retain their framework matrix. CLI-specific
exception-detail skips and library-only tests requiring in-process internals
remain explicit in the reports. The version-compatibility workflow runs both
variants against every configured database image. Its active CLI step uses
database containers; it does not execute the grate Docker distribution.

## Compare sizes for all profiles

```powershell
pwsh -NoProfile -File scripts/distributions/Measure-DistributionSizes.ps1 -OutputDirectory artifacts/distribution-sizes -RuntimeIdentifier linux-x64
```

This builds all six profiles with matching source, SDK, version, RID, trimming
and compression settings. It validates standalone/tool dependency manifests,
the four tool command declarations and ZIP round-trip hashes. `results.json`
records executable, ZIP and NuGet bytes. Use decimal MB and reductions from
unrounded values when reporting comparisons. Measurement builds do not require
running database servers; migration validation uses the runner above.

Keep logs and generated packages in ignored local artifacts or CI artifacts,
and record measured results in the PR or release record.

The former four-profile comparison wrapper and its Python drivers have been
removed. The current build, validation and size-comparison entry points cover
all six profiles.

[Distribution design and channel identities](design/database-specific-distributions.md)
