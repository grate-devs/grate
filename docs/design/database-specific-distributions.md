# Database-specific CLI and .NET tool distributions

Offer ready-to-run downloads and installable .NET tools for individual databases
alongside the existing all-in-one releases. The distribution choices are tracked
in #909, and the broader provider architecture has its own discussion.
[Distribution issue #909](https://github.com/grate-devs/grate/issues/909) ·
[Architecture issue #891](https://github.com/grate-devs/grate/issues/891)

The Linux x64 PoC builds `All`, `SQLite`, `SQLServer` and `MariaDB`, installs
the tools from local packages, runs migrations against the respective databases
and compares artifact sizes. Packaging mode also builds Linux amd64 Docker
images and Debian packages and exercises their normal entry points.
[Run the PoC](slim-distributions-poc/README.md)

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

## Other distribution channels

The same four profiles can feed the other channels. The proposed names below
show SQLite as the example. SQL Server and MariaDB use the corresponding
`sqlserver` and `mariadb` identifiers. These are channel design proposals for
#909. The executable PoC covers Linux x64 ZIPs, NuGet tools, Linux amd64
Docker images and Debian packages.

| Channel | Existing all-in-one identity | Proposed SQLite selection | Installed command |
| --- | --- | --- | --- |
| GitHub ZIP | `grate-<rid>-self-contained-<version>.zip` | `grate-sqlite-<rid>-self-contained-<version>.zip` | `grate` |
| Docker | `gratedevs/grate:<version>` and `:latest` | `gratedevs/grate:sqlite-<version>` and stable alias `:sqlite` | `/app/grate` |
| Debian download | `grate_<version>_<arch>.deb` | `grate-sqlite_<version>_<arch>.deb`, package `grate-sqlite` | `/usr/bin/grate` |
| MSI download | `grate-msi-win-<arch>-<version>.msi` | `grate-sqlite-msi-win-<arch>-<version>.msi` | `grate.exe` |
| WinGet manifest | Generator's `grate-devs.grate` identity | Proposed ID `grate-devs.grate.SQLite` | `grate` |
| Chocolatey | Package `grate` | Package `grate-sqlite` | `grate` |
| Homebrew cask | `erikbra/cask/grate` | Proposed `erikbra/cask/grate-sqlite` | `grate` |
| Homebrew formula | Source-built `grate` template | Proposed formula `grate-sqlite`, subject to channel acceptance | `grate` |

ZIP users select a directory, and container users select an image. For package
managers, propose one active grate variant per managed installation. Document
removing the installed variant before selecting another, and detect conflicting
variants before changing shared files, shims or PATH. Each manager controls
its own installation records. Document how users verify the selected `grate` when
mixing installation methods.

### ZIPs and Docker

Extend standalone publishing with the distribution dimension and reuse the
matching verified output in downstream installers. Match the current RID
support explicitly. The Linux x64 PoC provides execution evidence for that RID.
Each additional Windows, macOS, Arm64 and musl build needs its own packaged
checks. Release downloads should group assets by provider and platform so users
can find one artifact without scanning the complete matrix.

Docker uses Alpine and musl builds for amd64/arm64. The Dockerfile accepts
`GRATE_DISTRIBUTION` and passes `GrateDistribution` to `dotnet publish`. The
release proposal would keep one checked OCI archive
and multi-platform digest per profile. Add a distribution label so verification
can match the selected profile to its payload and expected platforms.
[Docker build](../../installers/docker/Dockerfile)

The entrypoint supplies `--databasetype` only when `DATABASE_TYPE` has a value.
The compiled CLI supplies the profile default when the variable is unset or
empty. The packaging checks exercise these defaults, environment overrides,
argument forwarding and unsupported database selections.
[Entrypoint](../../installers/docker/entrypoint.sh)

Use profile-prefixed tags such as `sqlite-<version>`, `sqlserver-<version>`
and `mariadb-<version>`. A suffix such as `<version>-sqlite` can collide with
a valid all-in-one SemVer prerelease tag. Stable releases can update `:sqlite`,
`:sqlserver` and `:mariadb`. Prereleases publish only their versioned tags.
Keep version parsing separate from tag rendering, and validate complete tags.
The proposal adds new variants under the canonical repository. The existing
compatibility-image policy continues to govern the all-in-one image.
[Tag policy](../../installers/docker/release_tags.py) ·
[Digest-preserving publication](../../installers/docker/RELEASE.md)

### Debian

The Debian recipe accepts `Distribution` and `OutputDirectory`, selecting the
package ID, description, document paths, maintainer scripts and filename. Each
slim package installs its selected binary at `/usr/bin/grate`. Its metadata
declares conflicts with the other variants. Switching uses explicit removal
and installation. A dependency requiring
the full provider set should continue to select the all-in-one package. Keep
Debian version ordering, including the existing prerelease conversion, separate
from the provider name. The current channel publishes downloadable .deb files.
[Debian recipe](../../installers/deb/Create-Package.ps1) ·
[Package relationships](https://www.debian.org/doc/debian-policy/ch-relationships.html)

Give each package its own `/usr/share/doc/<package>` content. The common binary
and manpage paths participate in the package-conflict policy. Test install,
same-variant upgrade, remove and purge with the matching database. Then test a
variant switch while preserving migration files, database contents and history.
[Existing lifecycle test](../../installers/deb/Verify-PackageLifecycle.sh)

### MSI, WinGet and Chocolatey

MSI needs a distribution-aware identity contract. Propose a stable UpgradeCode
for each new profile/architecture family, and a ProductCode derived from
profile, architecture and full release version. Preserve the existing all-in-one
identity derivation and family. Give new families their own display names,
installation paths, registry keys and component identities. Reject another installed grate variant
in the relevant installation scope before changing files or PATH. Switching
variants is an explicit uninstall/install operation, including at the same
version. This also requires checking how the legacy-product detection applies
to each profile. [Current identity contract](../../installers/msi/identity-contract.json) ·
[MSI template](../../installers/msi/grate.wxs) ·
[ProductCode](https://learn.microsoft.com/en-us/windows/win32/msi/productcode) ·
[UpgradeCode](https://learn.microsoft.com/en-us/windows/win32/msi/upgradecode)

WinGet can expose each variant under a separate package ID and generate its
URLs, hashes, ProductCode and upgrade metadata from that variant's final MSI.
The current generator also handles portable ZIPs, whose aliases need the same
single-command policy. Test install, upgrade, uninstall and source correlation
per ID, followed by switching between variants. Publishing candidates to the
community repository remains a channel acceptance step.
[Manifest generator](../../installers/winget/Create-Installer.ps1) ·
[Existing identity migration](../../installers/winget/MIGRATION.md) ·
[WinGet manifest identity](https://learn.microsoft.com/en-us/windows/package-manager/package/manifest)

Chocolatey can use one package ID per variant, embedding the corresponding
verified Windows x64 executable. Parameterize the nuspec, output directory and
verification URL/hash. Its common `grate.exe` shim requires an install-time
check for another installed grate package before accepting a variant. Test that
upgrade and uninstall operate on the selected package's shim and payload.
[Chocolatey recipe](../../installers/chocolatey/Create-Package.ps1) ·
[Executable shimming](https://docs.chocolatey.org/en-us/features/shim/)

### Homebrew

For the existing cask channel, generate a cask per selected profile from its final
Intel and Arm64 macOS ZIPs. Keep `binary "grate"` and declare conflicts with
other grate casks. Verify the interaction with a linked grate formula as well.
Update both the manual cask generator and automated tap-update path to select
the profile's archives and hashes.
[Cask generator](../../installers/homebrew/Create-Cask.ps1) ·
[Automated cask update](../../scripts/release/update_homebrew_cask.py) ·
[Cask conflict declarations](https://docs.brew.sh/Cask-Cookbook#stanza-conflicts_with)

For the source-built formula, pass `-p:GrateDistribution=<profile>` through
its existing publish command and expose `grate` from the formula's own
`libexec`. Use formula conflict declarations for competing grate commands.
Separate slim formulae require upstream acceptance. Their placement should be
agreed with the channel maintainers alongside the current source-formula work.
The existing formula test runs SQLite, so SQL Server and MariaDB variants need
an appropriate database verification arrangement before claiming formula
coverage. [Formula template](../../installers/homebrew/grate.rb.in) ·
[Homebrew channel plan](../../installers/homebrew/README.md) ·
[Formula conflicts](https://docs.brew.sh/Formula-Cookbook#specifying-conflicts-with-other-formulae)

### Release and verification cost

Use one profile catalog for names, CLI build properties, supported providers and
package-manager identities. Have builders and release validation consume the
selected channel/profile matrix. Installer jobs should wrap the matching checked
binary from that run. Docker musl and Homebrew source builds retain their own
build and verification paths. Record the profile in artifact metadata so a
correct filename alone cannot select an all-in-one payload for a slim package.

If all four profiles covered every current platform, the primary output counts
would grow as follows. This is a planning comparison for choosing coverage.

| Output | All-in-one today | Four profiles at current coverage |
| --- | ---: | ---: |
| Standalone ZIPs, nine RIDs | 9 | 36 |
| MSI, x64/Arm64 | 2 | 8 |
| Debian, amd64/Arm64 | 2 | 8 |
| NuGet tools | 1 | 4 |
| Docker multi-platform images | 1 | 4 |

The ZIP/MSI/Debian release inventory would therefore grow from 13 to 52 files,
plus checksum and manifest files. Measure installer and image download sizes in
MB independently. The Linux glibc ZIP measurements do not establish Alpine
image sizes or Windows/macOS installer savings.

The existing MSI, Debian, Docker-entrypoint and Homebrew tests use SQLite.
Retain that fixture for All/SQLite and use SQL Server or MariaDB for their slim
variants. Every channel needs a real migration/rerun through its installed entry
point, unsupported-provider rejection, bundled-skill verification, and clean
upgrade/uninstall behavior. Bind those checks to the artifacts being released.
[Package lifecycle checks](../Packaging.md#package-lifecycle-checks-in-ci)

The packaging PoC exercises Docker musl-x64 and installed Debian amd64 packages
for the three providers. Additional architectures, the Windows installer/identity
chain and macOS Homebrew validation require their own runner coverage. Select
which channels and profiles should ship through #909.

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
