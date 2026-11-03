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

Debian package metadata maps a SemVer prerelease such as `2.2.0-rc.1` to
`2.2.0~rc.1-1`, so Debian orders it before the final `2.2.0-1` package.
Release asset filenames retain the original SemVer version.

MSI generation uses checksum-pinned WiX 3.14.1, whose compiler supports Arm64.
Pass `-arch x64` or `-arch arm64` to `installers/msi/Create-Installer.ps1` to
match the input executable. Windows Installer 5.0 is required by the Arm64 MSI.

Inspect the produced runtime configuration/dependency metadata and run the
packaged executable, a representative migration and `grate skills install` on
the applicable native platform. A successful cross-build alone is not execution
evidence for that platform. Keep the runtime version and any build-only platforms
in the PR/release verification record.

## Package-manager updates after a release

These channels wrap the release binaries. They do not retarget or rebuild grate.
Generate their references and checksums from the **final published release
artifacts**. Do not edit the historical manifests in `installers/winget/grate` or
invent checksums for an unreleased version. The commands below generate local
files/packages; submission to the external repositories/feeds is separate.

- **Homebrew:** download both final macOS ZIPs and run
  `./installers/homebrew/Create-Cask.ps1 -version <version> -artifactDirectory <download-directory>`.
  Review the generated `installers/homebrew/grate.rb`, including the SHA256 of
  each archive, and update [erikbra/homebrew-cask](https://github.com/erikbra/homebrew-cask/blob/main/Casks/grate.rb).
  Install and smoke-test each native architecture using that cask.
- **Chocolatey:** extract `grate-win-x64-self-contained-<version>.zip` and run
  `./installers/chocolatey/Create-Package.ps1 -grateExe <extracted-grate.exe> -version <version>`
  on a machine with Chocolatey installed. It embeds the executable and records
  its SHA256 in `tools/VERIFICATION.txt`. Check the generated `.nupkg` and install
  it from a local source before submitting it to the Chocolatey feed.
- **WinGet:** for a stable release with corrected MSI identity, run
  `./installers/winget/Create-Installer.ps1 -version <version> -PrepareMigration`.
  The release workflow prepares the same new-ID candidate after uploading the
  final assets. It verifies asset URLs and actual MSI hashes/identity; submission
  remains separate. Default mode is reserved for historical old-identity MSIs
  and rejects corrected payloads. Do not submit those payloads under `erikbra.grate`.
  Review the generated `grate-devs.grate` manifests, run
  `winget validate --manifest <manifest-directory>` and verify installation and
  migration with the final files before submitting to `microsoft/winget-pkgs`.
  See the [migration contract and Windows evidence](https://github.com/grate-devs/grate/blob/main/installers/winget/MIGRATION.md)
  for the different MSI and portable transition commands and pending public acceptance.

Use `-releaseTag <tag>` with the Homebrew/winget generators if the release tag
differs from the numeric grate version. External channel publication and native
installation checks remain release steps, because final asset checksums are not
available while preparing the source PR.

## Moving to .NET 11 GA

Update the SDK in `global.json`, the bundled runtime version used by publishing,
and both Docker base-image tags/digests together. Rebuild every self-contained
binary, installer and Docker image, then regenerate package-manager references
and checksums. Updating the host's .NET installation does not service an embedded
runtime. Keep the existing .NET 8/9/10 targets unless a separate support decision
changes them.
