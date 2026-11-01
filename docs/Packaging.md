---
title: "Building and releasing packages"
permalink: /packaging/
nav_order: 11
---

# Building and releasing packages

The SDK is pinned in `global.json` to `11.0.100-rc.3.26522.148`. Library and
.NET tool packages retain `net8.0`, `net9.0` and `net10.0` assets and add `net11.0`.
Self-contained binaries and the Docker image bundle runtime
`11.0.0-rc.3.26522.148`. RC3 has [go-live production support](https://dotnet.microsoft.com/platform/support/policy/dotnet-core)
until November 10, 2026, so a grate release need not wait for .NET 11 GA.

The pinned SDK is used for normal repository builds. Developers who only need
to work on `net10.0` can use the stable .NET 10 SDK with the
[documented limited build workflow](https://github.com/grate-devs/grate/blob/main/CONTRIBUTING.md#working-with-the-stable-net-10-sdk).

## Build outputs

The Build and Publish workflow produces the existing distribution formats:

| Format | Outputs |
| --- | --- |
| NuGet libraries and symbols | `grate.core`, `grate.mariadb`, `grate.oracle`, `grate.postgresql`, `grate.sqlite`, `grate.sqlserver` |
| .NET tool | `grate` with .NET 8/9/10/11 assets |
| Self-contained ZIPs | `win-x86`, `win-x64`, `win-arm64`, `linux-x64`, `linux-arm64`, `linux-musl-x64`, `linux-musl-arm64`, `osx-x64`, `osx-arm64` |
| MSI | Windows x64 and Arm64, built from the corresponding self-contained binaries |
| Debian | Linux amd64 and Arm64, built from the corresponding self-contained binaries |
| Docker | Linux amd64 and Arm64 on Alpine 3.24, including ICU |

MSI generation uses checksum-pinned WiX 3.14.1, whose compiler supports Arm64.
Pass `-arch x64` or `-arch arm64` to `installers/msi/Create-Installer.ps1` to
match the input executable. Windows Installer 5.0 is required by the Arm64 MSI.

Inspect the produced runtime configuration/dependency metadata and run the
packaged executable, a representative migration and `grate skills install` on
the applicable native platform. A successful cross-build alone is not execution
evidence for that platform. Keep the runtime version and any build-only platforms
in the PR/release verification record.

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
- **Chocolatey:** extract `grate-win-x64-self-contained-<version>.zip` and run
  `./installers/chocolatey/Create-Package.ps1 -grateExe <extracted-grate.exe> -version <version>`
  on a machine with Chocolatey installed. It embeds the executable and records
  its SHA256 in `tools/VERIFICATION.txt`. Check the generated `.nupkg` and install
  it from a local source before submitting it to the Chocolatey feed.
- **winget:** install Microsoft's [wingetcreate](https://github.com/microsoft/winget-create),
  then run `./installers/winget/Create-Installer.ps1 -version <version>`.
  It downloads and hashes the three Windows ZIPs and two MSIs to match the
  [community manifest](https://github.com/microsoft/winget-pkgs/tree/master/manifests/e/erikbra/grate).
  Review the generated URLs, SHA256 values, architectures and MSI metadata;
  run `winget validate <manifest-directory>` and test local installation before
  submitting an update to `microsoft/winget-pkgs`.

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
