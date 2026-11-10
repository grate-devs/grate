---
title: "Building and releasing packages"
permalink: /packaging/
nav_order: 11
---

# Building and releasing packages

For the step-by-step maintainer procedure, follow the [release runbook](ReleaseProcess.md).
This page is the reference for SDK/runtime choices, output formats and manual
package generation. Publication identities are covered in
[Release configuration](ReleaseConfiguration.md).

The SDK is pinned in `global.json` to `11.0.100-rc.3.26522.148`. Library and
.NET tool packages retain `net8.0`, `net9.0` and `net10.0` assets and add `net11.0`.
Self-contained binaries and the Docker image bundle runtime
`11.0.0-rc.3.26522.148`. RC3 has [go-live production support](https://dotnet.microsoft.com/platform/support/policy/dotnet-core)
until November 10, 2026, so a grate release need not wait for .NET 11 GA.
We will update the SDK and bundled runtime to stable .NET 11 as soon as it is
released, following the [GA update procedure](#moving-to-net-11-ga) below.

The pinned SDK is used for normal repository builds. Developers who only need
to work on `net10.0` can use the stable .NET 10 SDK with the
[documented limited build workflow](https://github.com/grate-devs/grate/blob/main/CONTRIBUTING.md#working-with-the-stable-net-10-sdk).

## Build outputs

The Build and Publish workflow produces the existing distribution formats:

| Format | Outputs |
| --- | --- |
| NuGet libraries and symbols | `grate.core`, `grate.mariadb`, `grate.oracle`, `grate.postgresql`, `grate.sqlite`, `grate.sqlserver` |
| .NET tools | All six profiles with .NET 8/9/10/11 assets |
| Self-contained ZIPs | `win-x86`, `win-x64`, `win-arm64`, `linux-x64`, `linux-arm64`, `linux-musl-x64`, `linux-musl-arm64`, `osx-x64`, `osx-arm64` |
| Optional NativeAOT ZIPs | All six profiles on the same nine platforms, using `-nativeaot-` in the filename |
| MSI | Windows x64 and Arm64, built from the corresponding self-contained binaries |
| Debian | Linux amd64 and Arm64, built from the corresponding self-contained binaries |
| Docker | Linux amd64 and Arm64 on Alpine 3.24, including ICU |
| Chocolatey candidates | Six Windows x64 packages, retained without feed submission |
| WinGet candidates | Six identities wrapping each profile's final stable MSI/ZIP assets |
| Homebrew candidates | Six Intel/Arm64 casks and six source-built formulas |

CLI ZIP, MSI, Debian and Docker outputs cover All, SQLite, SQLServer, MariaDB,
PostgreSQL and Oracle. Names use `grate` for All and `grate-<database>` for slim
profiles; see [distribution identities](distributions.md). All variants expose
`grate`; uninstall the existing package before switching profiles.
The generated [distribution catalog](distribution-catalog.md) lists every
platform/package permutation with release filenames and build-result links.

NativeAOT is an additional archive option in this checkout. NuGet libraries and
tools and the existing installer/package-manager channels retain their normal
builds. The [NativeAOT build instructions](distributions.md#optional-nativeaot-archives)
cover native toolchains, full trimming, Dapper.AOT and complete ZIP extraction.

Debian package metadata maps a SemVer prerelease such as `2.2.0-rc.1` to
`2.2.0~rc.1-1`, so Debian orders it before the final `2.2.0-1` package.
Release asset filenames retain the original SemVer version.

MSI generation uses checksum-pinned WiX 3.14.1, whose compiler supports Arm64.
Pass `-arch x64` or `-arch arm64` to `installers/msi/Create-Installer.ps1` to
match the input executable. Windows Installer 5.0 is required by the Arm64 MSI.
Pass `-Distribution SQLite` (or another profile) to select its distinct installer
family. The generator verifies the executable's product/profile and version
metadata before packaging it; All's existing identity remains unchanged.

Inspect the produced runtime configuration/dependency metadata and run the
packaged executable, a representative migration and `grate skills install` on
the applicable native platform. A successful cross-build alone is not execution
evidence for that platform. Keep the runtime version and any build-only platforms
in the PR/release verification record.

## Package lifecycle checks in CI

The existing native packaging jobs also exercise the distribution boundaries:

- **NativeAOT ZIPs, every profile/platform:** verify the pinned native compiler and
  runtime pack, selected provider dependencies, complete payload and ZIP hashes,
  then execute the extracted CLI and bundled skill. All/SQLite also migrate and
  rerun SQLite on each native host. Separate database jobs run the existing
  command-line suites against the same run's Linux x64 NativeAOT release ZIPs
  for All and each provider, including case-sensitive SQL Server. Twelve checks
  retain the provider defaults; another 42 match the ordinary CLI's complete
  database-version/image matrix. Both groups gate the release contract; they
  keep the test runner itself as a normal build. Other RIDs have native smoke
  coverage rather than the full server-version matrix.
- **MSI, every profile on Windows x64 and Arm64:** install the candidate MSI per user,
  check payload identity, provider selection, rejection and bundled skills,
  then apply an explicit Windows
  Installer major upgrade with a newer executable, then uninstall. The check
  verifies installed payloads, product registration and cleanup while preserving
  unrelated user data. This tests the per-release ProductCode and stable
  profile/architecture-specific UpgradeCode family used by the installer.
  All/SQLite run a disposable SQLite migration; server-profile migrations are
  exercised by the Linux CLI/tool suites, not this Windows lifecycle fixture.
- **Debian, Linux amd64 and Arm64:** install test package `0.0.1-1` in a disposable
  Ubuntu container, migrate and rerun through `/usr/bin/grate`, upgrade to
  `0.0.2-1`, then purge. Both packages wrap the same candidate executable, so this
  verifies the package-version transition and data preservation rather than a
  change to the application binary.
- **Docker, Alpine amd64 and Arm64:** run the image with its default entrypoint,
  environment configuration and documented mounts. Check argument forwarding,
  dry runs, migration/rerun effects and failure exit codes in addition to the
  existing direct-executable, globalization and bundled-skill checks.

The lifecycle test entry points run in PowerShell on the host. Debian's package
operations and assertions run in shell inside its disposable Ubuntu container.
Docker entrypoint verification uses the host's SQLite CLI for independent,
read-only database assertions; CI ensures that client is available.

These checks use local test artifacts and disposable state. Installer logs and
verification diagnostics are uploaded even when a job fails. They do not publish
packages or replace the final release-asset checks below.

## Package-manager updates after a release

Chocolatey, winget and the existing Homebrew cask wrap the release binaries.
The proposed Homebrew/core formula instead builds from the tagged source and uses
Homebrew's shared .NET runtime; its preparation is described below.
Generate their references and checksums from the **final published release
artifacts**. Do not edit the historical manifests in `installers/winget/grate` or
invent checksums for an unreleased version. The commands below generate local
files/packages; submission to the external repositories/feeds is separate.

- **Homebrew cask (existing personal tap):** download both final macOS ZIPs and run
  `./installers/homebrew/Create-Cask.ps1 -version <version> -artifactDirectory <download-directory>`.
  Review the generated `artifacts/homebrew/cask/grate.rb`, including the SHA256 of
  each archive, and update [erikbra/homebrew-cask](https://github.com/erikbra/homebrew-cask/blob/main/Casks/grate.rb).
  Install and smoke-test each native architecture using that cask.
  Add `-AllDistributions` to generate six casks from all twelve profile ZIPs,
  or select one with `-Distribution SQLite`.
- **Chocolatey:** extract `grate-win-x64-self-contained-<version>.zip` and run
  `./installers/chocolatey/Create-Package.ps1 -grateExe <extracted-grate.exe> -version <version>`
  on a machine with Chocolatey installed. It embeds the executable and records
  its SHA256 in `tools/VERIFICATION.txt`. Check the generated `.nupkg` and install
  it from a local source before submitting it to the Chocolatey feed.
  Use `-Distribution SQLite` for a selected executable, or
  `-AllDistributions -ArtifactDirectory <final-windows-x64-zips>` instead of
  `-grateExe` to prepare all six packages. The workflow retains these same
  candidates; it does not submit them to Chocolatey.
- **WinGet:** for a stable release with corrected MSI identity, run
  `./installers/winget/Create-Installer.ps1 -version <version> -PrepareMigration`.
  The release workflow prepares the same new-ID candidate after uploading the
  final assets. It verifies asset URLs and actual MSI hashes/identity; submission
  remains separate. Default mode is reserved for historical old-identity MSIs
  and rejects corrected payloads. Do not submit those payloads under `erikbra.grate`.
  Review the generated `grate-devs.grate` manifests, run
  `winget validate --manifest <manifest-directory>` and verify installation and
  migration with the final files before submitting to `microsoft/winget-pkgs`.
  See the [migration contract and Windows verification](https://github.com/grate-devs/grate/blob/main/installers/winget/MIGRATION.md)
  for the different MSI and portable transition commands and pending public acceptance.
  Add `-Distribution SQLite` (or another profile) for its separate
  `grate-devs.grate.SQLite` identity. The stable workflow retains all six
  candidates; new IDs need upstream acceptance before public installation.

Use `-releaseTag <tag>` with the Homebrew/winget generators if the release tag
differs from the numeric grate version. External channel publication and native
installation checks remain release steps, because final asset checksums are not
available while preparing the source PR.

## Homebrew/core formula

The source-built formula is being prepared for grate 2.2.0. It is not yet available
from `homebrew/core`. The template and generation helper can be included in the
grate release before Homebrew accepts the formula; Homebrew acceptance does not
block publishing grate 2.2.0.

`installers/homebrew/grate.rb.in` is the reference template. It uses `dotnet` as
both a build and runtime dependency and publishes with `--no-self-contained`.
The apphost locates Homebrew's .NET installation, and Homebrew installs that dependency
for users. The formula selects the target framework matching Homebrew's SDK rather
than the .NET 11 RC3 runtime bundled in the self-contained release archives.

After the final stable tag exists, download its source archive and generate the
formula. For 2.2.0, run from the repository root:

```sh
mkdir -p artifacts/homebrew
curl --fail --location \
  --output artifacts/homebrew/grate-2.2.0.tar.gz \
  https://github.com/grate-devs/grate/archive/refs/tags/2.2.0.tar.gz
pwsh -File installers/homebrew/Create-Formula.ps1 \
  -version 2.2.0 \
  -sourceArchive artifacts/homebrew/grate-2.2.0.tar.gz
```

The helper hashes the supplied source archive and writes
`artifacts/homebrew/formula/grate.rb`. Use `-releaseTag v2.2.0` if the tag has a
`v` prefix, and download the archive for that exact tag. The cask
and formula generators have separate output directories. Neither helper publishes
anything or updates an external repository.
Add `-AllDistributions` to render all six source-formula candidates, or use
`-Distribution SQLite` to select one. Both stable and HEAD builds pass the
selected `GrateDistribution` to MSBuild. Server-profile formula tests check
provider help, rejection and skills; real server migrations through Homebrew
remain a separate native check. New formula IDs require channel acceptance.

Review the generated URL and SHA256 against the archive that was downloaded,
then copy the formula to `Formula/g/grate.rb` in the `grate-devs/homebrew-core` fork.
Build and test the final tagged source using Homebrew's contributor workflow:

```sh
HOMEBREW_NO_INSTALL_FROM_API=1 brew install --build-from-source grate
brew test grate
brew linkage --test --strict grate
brew audit --new --strict --online grate
brew style --formula grate
```

These checks require the formula to be registered in a local Homebrew tap; copying
it only into an arbitrary clone does not make `brew install grate` find it.
Follow Homebrew's [contributor setup instructions](https://docs.brew.sh/How-To-Open-a-Homebrew-Pull-Request)
to register the local core tap.
Verify a real migration and runtime discovery on the applicable macOS and Linux
architectures. Validate the final tagged source even if earlier builds from `HEAD`
passed, and record the source version, SDK, runtime, OS and architecture tested.

Submit the generated formula and check results to `Homebrew/homebrew-core`,
coordinating with maintainers about the existing submission
[Homebrew/homebrew-core#296651](https://github.com/Homebrew/homebrew-core/pull/296651).
Keep the installation documentation marked as pending until the formula is accepted,
then make `brew install grate` the normal Homebrew instruction.

## Moving to .NET 11 GA

Update the SDK in `global.json`, the bundled runtime version used by publishing,
and both Docker base-image tags/digests together. Rebuild every self-contained
binary, installer and Docker image, then regenerate package-manager references
and checksums. Updating the host's .NET installation does not service an embedded
runtime. Keep the existing .NET 8/9/10 targets unless a separate support decision
changes them.
