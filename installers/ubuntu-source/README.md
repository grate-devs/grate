# Ubuntu archive source-package feasibility recipe

This recipe investigates [#920](https://github.com/grate-devs/grate/issues/920)
using the MariaDB profile from [#910](https://github.com/grate-devs/grate/pull/910).
It creates a conventional `3.0 (quilt)` source package, then attempts a trimmed,
self-contained .NET 10 binary build from official Ubuntu archive inputs.
The `UNRELEASED` changelog identifies a local experiment, not a submission or
claim of archive acceptance.

Ubuntu 26.04 LTS supplies the initial SDK/source-built-artifact baseline.
Development-release selection, .NET 11 availability, older-LTS support and sponsor
review need separate assessment. Microsoft SDK images, Canonical's backports PPA
and nuget.org are different input sources; substituting them does not establish
an official-archive build.

## Run an isolated attempt

Host requirements: PowerShell 7, git, tar and Docker. Provisioning installs
packaging tools, implicit `build-essential` and declared build inputs from the
base image's Ubuntu repositories. Provisioning uses networking; source and binary
builds do not. Inspect apt sources and pin the base digest for formal evidence.
From the repository root:

```powershell
docker build --file installers/ubuntu-source/Builder.Dockerfile `
    --build-arg UBUNTU_IMAGE=ubuntu:26.04 `
    --tag grate-ubuntu-source:26.04 .
if ($LASTEXITCODE -ne 0) { throw 'Builder provisioning failed.' }

pwsh -NoProfile -File installers/ubuntu-source/Stage-Source.ps1 `
    -OutputDirectory /tmp/grate-source-attempt -Version 0.0.1 -UseUbuntuArchiveAnalyzer
pwsh -NoProfile -File installers/ubuntu-source/Invoke-OfflineBuild.ps1 `
    -StagedDirectory /tmp/grate-source-attempt `
    -EvidenceDirectory /tmp/grate-source-evidence `
    -Architecture arm64 `
    -DapperPackage /tmp/dapper-archive/packages-built/Dapper.2.1.89.nupkg `
    -MySqlConnectorPackage /tmp/mysqlconnector-ubuntu-net10/packages/MySqlConnector.2.6.2.nupkg
```

Before these stage/build commands, produce both packages using the
[source dependency recipes](dependencies/README.md). The runner validates their
IDs, versions and source revisions, records SHA-256 values, mounts the input feed
read-only and verifies restored ZIP bytes. Both packages must be supplied together.
No developer NuGet cache is copied.

`-UseUbuntuArchiveAnalyzer` opts into a recorded quilt patch changing only
NetAnalyzers `10.0.403` to the archive's `10.0.114`. The original compiler/analyzer
warning policy and embedded-runtime security floor remain. This is an explicit
packaging adaptation. Without this switch and the local packages, the original
missing-input experiment remains available.

Use a new stage/evidence directory each time. Staging exports committed source
with `git archive`, excluding developer caches, `bin`, `obj` and untracked files.
It rejects existing output, tracked binaries and uncommitted product changes.
The live `debian/` recipe is copied explicitly. Exact product SHA is recorded in
`source-origin.json` and `debian/source-revision`. Commit product changes first.
`-Version` selects the source directory/tarball, changelog and MSBuild version
together. Use `0.0.2` in a separate stage for the upgrade fixture; the Debian revision
remains `1~poc1`. These are local PoC versions, not published grate releases.

The runner uses a fresh disposable container, `--pull=never`, `--network=none`
and no developer caches. Its root remains writable for .NET's first-use/mutex
infrastructure. It records image inspection, installed package versions, SDK
information, arguments, logs and result metadata outside git.
`dpkg-buildpackage -S -us -uc` constructs source artifacts before the binary
attempt. Nonzero exits propagate. Preserve the `.dsc`, original and Debian
tarballs, source `.buildinfo` and `.changes` beside the logs for reproduction.
A source package alone does not establish a working executable.

For amd64, provision with `docker build --platform linux/amd64` and select
`-Architecture amd64`. Execution is emulated when the Docker engine architecture
differs. Record native/emulated status and unverified combinations explicitly.

## Input and packaging boundaries

`debian/control` declares available SDK/source-artifact inputs, native runtime
dependencies, package identity and conflicts. The artifact package is a toolchain
feed, not a complete application NuGet mirror. `debian/rules` extracts its flat
package feed and restores from that local source and the archive SDK's own
`/usr/lib/dotnet/library-packs`, using fresh caches.
Missing dependencies need archive-packaged source-built inputs or a reviewed
source-build plan. Adding prebuilt third-party `.nupkg` files does not establish
archive eligibility.

To test building the missing Dapper/MySqlConnector inputs from their exact
sources, use the [dependency experiments](dependencies/README.md). Those local
net10 nupkgs require explicit packaging adaptations and separate consumer checks;
they do not automatically become Ubuntu Build-Depends for this source recipe.

The recipe uses `ubuntu.26.04-arm64` / `ubuntu.26.04-x64` RIDs because Ubuntu's
source-built runtime and host packs carry those identifiers. A portable
`linux-arm64` / `linux-x64` request would need different packs. This does not
establish compatibility with other Ubuntu or Debian releases.

The SDK runs from `/` with an absolute project path, following the SDK 10
procedure in [CONTRIBUTING.md](../../CONTRIBUTING.md), avoiding the SDK 11 RC
`global.json` without changing it. Restore/publish explicitly select `net10.0`
and `GrateDistribution=MariaDB`. The embedded-runtime security floor remains.
Network-based NuGet advisory queries are disabled only inside this isolated
build; audit the exact dependency inventory separately before distribution.

The intended command is `/usr/bin/grate` in package `grate-mariadb`, without a
virtual `Provides: grate`. Variants conflict because they share that command.
There are no maintainer scripts deleting databases or user configuration.
The native dependency list targets Ubuntu 26.04 and needs installed-artifact
verification: embedded libraries are hidden from normal `dh_shlibdeps` scans.
Inspect the extracted bundle and verify native loading, TLS and globalization.
`dh_strip` and `dh_dwz` are disabled to preserve the appended single-file bundle.

The [offline notice helper](notices/README.md) runs after actual restore/publish
and covers that closure, installed Ubuntu runtime/ref/host packs and validated
original-source texts. Packaging requires its generated notice and JSON inventory;
an arbitrary caller-supplied notice file cannot satisfy the gate. Both are
installed uncompressed under `/usr/share/doc/grate-mariadb/`. Review actual
package contents, including full Apache terms and native/runtime notices. This
does not establish legal clearance or readiness for NEW.

The local nupkgs remain explicit PoC inputs, not archive-packaged Build-Depends.
The .dsc alone does not rebuild them. Replay requires their recorded source
recipes/archives and package hashes alongside the declared Ubuntu toolchain.
Installed and artifact-feed apphosts can have different bytes: supplier records
and both hashes are preserved without a bit-identical reproducibility claim.

Preserve exact missing package identities, versions and RIDs on restore failure.
The preferred self-contained result then remains blocked. Assess a
framework-dependent fallback separately: removing the embedded runtime does not
resolve application-source dependency requirements.

To repeat that fallback assessment with fresh source/caches and the same isolated
Ubuntu input feed, use a separate staging directory and restore-only mode:

```powershell
pwsh -NoProfile -File installers/ubuntu-source/Stage-Source.ps1 `
    -OutputDirectory /tmp/grate-source-fallback
pwsh -NoProfile -File installers/ubuntu-source/Invoke-OfflineBuild.ps1 `
    -StagedDirectory /tmp/grate-source-fallback `
    -EvidenceDirectory /tmp/grate-fallback-evidence `
    -Architecture arm64 -FrameworkDependentRestoreOnly
```

This constructs the source package, extracts the archive's local feed and runs
`dotnet restore` with no RID and `SelfContained`, `PublishTrimmed`,
`PublishSingleFile` and `UseAppHost` all false. It does not publish or package
framework-dependent output. A successful restore would still require a complete
framework-dependent install layout, shared-runtime dependency and installed
artifact verification before distribution.

## Verification

Run source/cache-isolation and failure-behavior regressions without a builder:

```powershell
pwsh -NoProfile -File installers/ubuntu-source/Test-SourceStaging.ps1
```

After a binary build succeeds, reuse
[slim-distribution verification](../../docs/design/slim-distributions-poc/README.md)
and the lifecycle work tracked in [#881](https://github.com/grate-devs/grate/issues/881).
Adapt its SQLite/all-provider verifier to MariaDB fixtures, names and independent queries
when that work is available on the chosen source baseline.
Verify installed help/defaults/omitted-provider errors, bundled skills and no
shared-runtime requirement. Run migration/rerun with independent data, script
hash/identity and history/version/error assertions. Exercise install, upgrade,
conflicts, deliberate switching, remove and purge with retained database state,
inspect packaged notices, and record actual architecture execution coverage.

The [installed MariaDB package verifier](tests/README.md) exercises this PoC in
a native-library-only Ubuntu environment, including no shared .NET, independent
migration/version/history assertions, upgrade and lifecycle.
