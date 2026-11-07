# Database-specific CLI and .NET tool distributions

Offer ready-to-run downloads and installable .NET tools for individual databases
alongside the existing all-in-one releases. The distribution choices are tracked
in #909, and the broader provider architecture has its own discussion.
[Distribution issue #909](https://github.com/grate-devs/grate/issues/909) ·
[Architecture issue #891](https://github.com/grate-devs/grate/issues/891)

The Linux x64 PoC builds `All`, `SQLite`, `SQLServer` and `MariaDB`, installs
the tools from local packages, runs migrations against the respective databases
and compares artifact sizes. [Run the PoC](slim-distributions-poc/README.md)

## Existing release build

- The default CLI build references all five provider projects and directly
  references `Microsoft.Data.SqlClient` and its Azure extensions. The CLI
  defaults to SQL Server. [CLI project](../../src/grate/grate.csproj)
- The release workflow publishes self-contained, single-file ZIPs per runtime
  identifier (RID), currently targeting `net11.0`. It also packs the
  framework-dependent `grate` tool with assets for each supported framework
  and builds six provider/core library packages separately.
  [Release workflow](../../.github/workflows/build.yml) ·
  [Framework targets](../../Directory.Build.props)
- The release workflow validates its expected GitHub asset list before generating
  `checksums.sha256` and `release-manifest.json`. The NuGet publisher validates
  seven package IDs at the release version. CI exercises standalone and installed
  tool builds. [CI workflow](../../.github/workflows/ci.yml) ·
  [Package verification script](../../scripts/verify-packages.ps1)

## Package choices demonstrated by the PoC

| Format | All-in-one | SQLite | SQL Server | MariaDB |
| --- | --- | --- | --- | --- |
| NuGet tool ID | `grate` | `grate-sqlite` | `grate-sqlserver` | `grate-mariadb` |
| Installed command | `grate` | `grate` | `grate` | `grate` |
| Default database | SQL Server | SQLite | SQL Server | MariaDB |
| ZIP prefix | `grate-` | `grate-sqlite-` | `grate-sqlserver-` | `grate-mariadb-` |

Each ZIP follows `<prefix><rid>-self-contained-<version>.zip` and contains
`grate` or `grate.exe`. Users select a package, then invoke the same command.

```sh
dotnet tool install --global grate-mariadb
grate --connectionstring "Server=localhost;Database=example;User ID=example;Password=example"
```

A global tool installation or a project tool manifest selects one variant.
Switching a global installation requires uninstalling the current package before
installing another variant with the same command name. The PoC uses separate
tool paths to verify every package. [.NET tool packaging](https://learn.microsoft.com/en-us/dotnet/core/tools/global-tools-how-to-create)

Each slim build accepts explicit selection of its database as well as its default.
Help and completions expose the selected provider, and an unsupported provider
produces a parse error before database services are constructed.

## Build-time provider selection

The CLI project uses `GrateDistribution` with `All` as the default. The three
slim profiles select their provider project and dependencies. For example, the
SQLite profile excludes the direct SQL Server client references as well as
the four other provider projects.

`DatabaseProviders` owns the compiled provider list, database option construction
and service registration. Its imports, provider list entries and switch arms each
have an individual `ALL_DATABASES || <PROVIDER>_ONLY` condition. The single-provider
default, help, completions and validation derive from that list. This lets
`MigrateCommand` and `Program` delegate provider configuration to one place.
[Provider configuration](../../src/grate/Configuration/DatabaseProviders.cs)

The package ID identifies the variant while `ToolCommandName` and the assembly
name are both `grate`. Each package includes a matching README. Migration
commands, logging and bundled skills use shared CLI code. Separate MSBuild
artifact roots keep the variants' restore and build outputs isolated.
[MSBuild artifact layout](https://learn.microsoft.com/en-us/dotnet/core/sdk/artifacts-output)

These commands build the SQL Server variant using a local candidate version.
CI would use the existing version outputs and SDK pin.

```sh
out="$PWD/artifacts/sqlserver-pilot"

dotnet publish src/grate/grate.csproj -c Release -f net11.0 -r linux-x64 \
  --self-contained -p:TargetFrameworks=net11.0 -p:GrateDistribution=SQLServer \
  -p:Version=0.0.1 -p:ArtifactsPath="$out/standalone-build" -o "$out/publish"

dotnet pack src/grate/grate.csproj -c Release \
  -p:PackAsTool=true -p:SelfContained=false -p:GrateDistribution=SQLServer \
  -p:Version=0.0.1 -p:PackageVersion=0.0.1-pilot \
  -p:ArtifactsPath="$out/tool-build" -o "$out/feed"
```

## Verification and size comparison

The PoC exercises every slim variant's extracted ZIP and installed tool against
its database, then reruns the migration with explicit provider selection. A
separate direct-client program queries data, script hashes/history and migration
errors after both invocations. The all-in-one packages exercise all three
databases using the same fixture and checks.

Each tool framework's metadata must declare command `grate`. Dependency checks
require the selected provider and client libraries, and exclude other provider
assemblies and clients from slim builds. Installed tool package bytes must
match the local build. Bundled skill installation is exercised as well.

Executable, ZIP and NuGet package sizes are compared using matching versions,
SDK, frameworks and compression. Standalone ZIPs include .NET, while tool
packages include four framework targets and their runtime assets. Measurements
and execution limits belong in the PR verification record. The runnable checks
and reproduction instructions are in the PoC directory.
[PoC verification](slim-distributions-poc/README.md)

## Add selected variants to the release contract

Once the released variants and platform coverage are agreed in #909, add them to
the existing release workflow with distinct Actions artifacts and the version
from `set-version-number`. Run the packaged checks against the candidates
that will be uploaded, and have `release-ready` require their successful results.
Add the ZIPs to the expected asset list so checksums and the manifest cover them.

Expand the NuGet allowlist to include the selected tool IDs. Shipping all three
slim tools would produce ten packages with the existing six libraries and
all-in-one tool. Validate the complete set and versions before publication.
Confirm availability of the new package IDs and that the NuGet trusted-publishing
policy permits their creation and subsequent versions.
[Release configuration](../ReleaseConfiguration.md) ·
[NuGet trusted publishing](https://learn.microsoft.com/en-us/nuget/nuget-org/trusted-publishing)

## Decisions for #909

- Which of the demonstrated variants should ship, and on which RIDs? The PoC
  covers Linux x64. Windows x64 and macOS Arm64 would extend the native test
  matrix and release asset list.
- Do the download savings justify maintaining more packages? Use the measurements
  to decide which providers and additional distribution channels warrant variants.
