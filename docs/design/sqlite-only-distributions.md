# SQLite-only CLI and .NET tool distributions

Offer a ready-to-run SQLite-only download and an installable .NET tool alongside
the existing all-in-one releases. Both SQLite formats would carry the same
migration engine and SQLite provider. The broader provider architecture has its
own discussion. [Distribution issue #909](https://github.com/grate-devs/grate/issues/909) ·
[Architecture issue #891](https://github.com/grate-devs/grate/issues/891)

## What the build does today

- The CLI project references all five provider projects and directly references
  `Microsoft.Data.SqlClient` and `Microsoft.Data.SqlClient.Extensions.Azure`.
  `Program.cs` selects the provider during service registration.
  `MigrateCommand` parses `--databasetype` and defaults to SQL Server.
  [CLI project](../../src/grate/grate.csproj) ·
  [Provider selection](../../src/grate/Program.cs) ·
  [Migration command](../../src/grate/Commands/MigrateCommand.cs)
- The release workflow uses that project to publish a self-contained
  single-file binary per runtime identifier (RID), currently targeting
  `net11.0`, and to pack the framework-dependent `grate` tool with assets
  for each supported target framework. It builds the six library packages
  separately. The SQLite provider library already references `grate.core`
  and `Microsoft.Data.Sqlite`. [Release workflow](../../.github/workflows/build.yml) ·
  [Framework targets](../../Directory.Build.props) ·
  [SQLite provider project](../../src/grate.sqlite/grate.sqlite.csproj)
- The release workflow checks the exact GitHub asset list before generating
  `checksums.sha256` and `release-manifest.json`. The NuGet publisher checks
  for exactly seven package IDs at the release version. CI exercises both
  standalone and installed-tool builds. [CI workflow](../../.github/workflows/ci.yml) ·
  [Package verification script](../../scripts/verify-packages.ps1)

## Proposed packages

| Format | All-in-one | SQLite-only |
| --- | --- | --- |
| GitHub release ZIP | `grate-<rid>-self-contained-<version>.zip` | `grate-sqlite-<rid>-self-contained-<version>.zip` |
| Executable inside ZIP | `grate` or `grate.exe` | `grate` or `grate.exe`, extracted to a separate directory |
| NuGet tool ID and installed command | `grate` | `grate-sqlite` |
| Default database | SQL Server | SQLite |

Users would install the tool with `dotnet tool install --global grate-sqlite`.
The distinct command lets both tools be installed side by side. The standalone binary keeps the same executable name so an existing SQLite script
can swap the binary by path. Both forms accept explicit `--databasetype sqlite`.
The SQLite build should show SQLite as its only supported database in help and
reject another database type with a clear error and a nonzero exit code before
initializing any database services. Keep the all-in-one provider selection and
default as they are today. [.NET tool packaging](https://learn.microsoft.com/en-us/dotnet/core/tools/global-tools-how-to-create)

The first set of ZIPs could cover `linux-x64`, `win-x64` and `osx-arm64`.
That adds three downloads to the release page and gives us a native smoke test
on each OS. Reuse the native macOS Arm64 runner for that bundle and use the
existing framework targets for the new .NET tool. Keep MSI, Debian, Docker
and the existing package-manager channels on the all-in-one build during the
pilot.

## Select providers at build time

Keep one CLI project with a build property such as `GrateDistribution`.
Default to `All` and fail the build for unknown values. When the value is
`SQLite`, include the SQLite project reference and condition out the four
other provider references and the two direct SQL Server client references.
Leave the shared CLI and existing SQLite dependency graph in place, including
the native SQLite assets and bundled `use-grate` skill. A runtime flag alone
would leave the unused clients in the package.

Move the provider-specific registrations out of `Program.cs` into two small
compile-time alternatives in the CLI project. Each supplies the supported
database types, the default and the registration logic. Let `MigrateCommand`
use that same information for help and validation. This keeps provider code
that needs the omitted assemblies out of the SQLite compilation and keeps the
migration command, logging and bootstrap path shared. A separate SQLite
executable project could also express the reference graph, but would require
extracting a shared CLI host or maintaining two entry points.

Set `PackageId` and `ToolCommandName` to `grate-sqlite` for the SQLite build,
keeping the assembly name `grate`. Include a tool README that explains the
SQLite-only scope and points to the all-in-one tool and the `grate.sqlite`
library. Use separate MSBuild artifact roots for each variant and build form
so one restore or build cannot reuse the other variant's `obj` or `bin`.
[MSBuild artifact layout](https://learn.microsoft.com/en-us/dotnet/core/sdk/artifacts-output)

These commands illustrate the proposed project changes using a local candidate
version. CI would use the existing version outputs and SDK pin.

```sh
out="$PWD/artifacts/sqlite-pilot"

dotnet publish src/grate/grate.csproj -c Release -f net11.0 -r linux-x64 \
  --self-contained -p:TargetFrameworks=net11.0 -p:GrateDistribution=SQLite \
  -p:Version=0.0.1 -p:ArtifactsPath="$out/standalone-build" -o "$out/publish"

dotnet pack src/grate/grate.csproj -c Release \
  -p:PackAsTool=true -p:SelfContained=false -p:GrateDistribution=SQLite \
  -p:Version=0.0.1 -p:PackageVersion=0.0.1-pilot \
  -p:ArtifactsPath="$out/tool-build" -o "$out/feed"
```

## Verify the packages before adding them to releases

1. Build the two SQLite formats as unpublished CI artifacts first. Extend the
   existing package smoke checks to exercise the extracted ZIP executable and
   the installed tool. Install the exact tool version from an isolated local
   feed using a temporary tool path and an explicit NuGet config.
   [Tool installation options](https://learn.microsoft.com/en-us/dotnet/core/tools/dotnet-tool-install)
2. On each proposed ZIP platform, run a real migration against a fresh SQLite
   file with the default database type, then rerun with `--databasetype sqlite`
   and check that the schema, seeded data and history show the one-time script
   ran once. Exercise the installed tool with each supported target framework
   on Linux and smoke-test its native SQLite loading on Windows and macOS.
   Check the unsupported-provider error and bundled skill installation on
   both packaged forms. Keep the existing all-in-one checks and verify that
   both tool commands resolve to their own installations.
3. Inspect the tool payload and dependency manifests for each framework, and
   the standalone bundle contents or recorded bundle inputs for each RID.
   Require SQLite's managed and native assets and exclude the other provider
   assemblies and their exclusive clients, including SqlClient, Npgsql,
   MySqlConnector and Oracle Managed Data Access. Verify the native SQLite
   version loaded by the migration against the existing security floor.
4. Compare ZIP bytes per RID and `.nupkg` bytes against all-in-one builds from
   the same commit, version and SDK. Keep the compression and runtime settings
   matched. Record bytes and percentage saved for each format. The standalone
   ZIP still includes .NET, so measure its savings separately from the tool.

## Add the pilot to the release contract

Once the pilot scope is agreed, add the SQLite builds to the existing
`build.yml` release path using the version from `set-version-number`.
Give their Actions artifacts distinct names. Run the artifact checks against
the candidates that will be uploaded and have `release-ready` require
their successful results. Add the selected ZIPs to its expected asset list
so the same checksums and manifest cover both variants. Expand the NuGet
allowlist from seven IDs to eight and validate the complete set and versions
before the first push. Use the existing release-only publication conditions
and promote the checked files from that run.

Confirm availability of the `grate-sqlite` package ID and that the existing
NuGet trusted-publishing policy permits creating it and publishing subsequent
versions. Update the installation guide and release runbook when the pilot
ships. [Release configuration](../ReleaseConfiguration.md) ·
[NuGet trusted publishing](https://learn.microsoft.com/en-us/nuget/nuget-org/trusted-publishing)

## Decisions for #909

- Are three ZIP platforms the right starting point? Linux x64 alone would
  keep the initial release smaller. Matching every current RID would give
  users the same platform coverage and increase the native test matrix.
- Is the measured download saving worth the extra artifacts and support
  surface? Use the SQLite pilot to decide which, if any, additional providers
  or distribution channels warrant their own variants.
