# Ubuntu archive dependency investigation

This is the reusable dependency procedure for [issue #920](https://github.com/grate-devs/grate/issues/920).
Read the [archive feasibility assessment](ubuntu-archive.md) and
[source-package recipe](../../installers/ubuntu-source/README.md) for the decision
and build attempt. Exact resolved versions, source metadata, hashes, copied
license texts and logs belong in the linked investigation artifact. Upstream
NuGet packages are discovery inputs; restoring them does not establish an
acceptable source build for Ubuntu.

The [Dapper and MySqlConnector source experiments](../../installers/ubuntu-source/dependencies/README.md)
provide a bounded way to investigate those missing inputs and exercise rebuilt
packages with a real MariaDB consumer. Keep the adapted dependency graph and
results separate from the original upstream-NuGet discovery matrices below.

## Reproduce the matrix

Use Docker and PowerShell 7 on the host. Pull the SDK image matching `global.json`
first; specify a digest with `-SdkImage` when archiving a repeatable run. The
runner records the resolved local image ID/digests/architecture, committed source
revision and source archive hash. It rejects an existing output directory and
uses a fresh source snapshot, CLI home, package folder and HTTP cache. The image's
SDK and installed reference/apphost packs remain explicit prebuilt discovery
inputs. Uncommitted source edits are excluded deliberately.

```powershell
pwsh scripts/ubuntu-archive/Invoke-DependencyInventory.ps1 `
    -OutputDirectory /tmp/grate-archive-inventory `
    -AllowOnlineRestore
```

The optional `-LicenseSourceCacheDirectory /path/to/audit/scripts/licenses`
consumes the compliance audit's `sources.json` and `text/` directory read-only.
Every cached text must match its recorded SHA-256 and the restored package's
repository commit. Without that cache, packages missing original license texts
are explicitly marked; SPDX identifiers alone do not supply original copyright
notices. This reuses the audit's source-license evidence without importing its
unfinished implementation.

The plan restores MariaDB, SQLite, SQLServer and All for `net11.0` on `linux-x64`
and `linux-arm64`, plus the MariaDB `net10.0` archive baseline on both RIDs. It
separately restores the PostgreSQL **library**, because a PostgreSQL-only CLI
profile is not implemented. `All` still includes Oracle. There is no compiled
all-except-Oracle profile: assess its prospective closure as the union of the
non-Oracle provider closures, then repeat actual CLI restore/publish after
implementing that profile. A library graph or set subtraction does not establish
a new CLI variant's registration, default, help, trimming or output contents.

| Artifact | Meaning |
| --- | --- |
| `dependency-matrix.json` | Exact managed/build/runtime/download versions; direct-project references versus transitive packages; nuspec repository/commit; feed/content hash; selected-target assets and native files present in restored packages |
| `dependency-matrix.csv` | Flat source/license/provenance matrix; JSON retains the asset details |
| `texts/` | Byte-preserved original package licenses/NOTICEs and hash-validated source-cache texts |
| `sdk-inputs.json`, `sdk-*LICENSE*`, `sdk-*NOTICES*` | SDK and installed pack inventory and SDK licensing material, separate from downloaded packages |
| `*-restore.log`, `sdk-info.txt`, `run-manifest.json` | Restore outcomes and discovery environment; no successful source rebuild is implied |
| `prospective-all-except-oracle-*.json` | Explicitly inferred union with references to full source/license rows; not a compiled or independently resolved CLI graph |

Runtime `downloadDependencies` are included even though they are absent from the
assets file's ordinary `libraries` list. This catches runtime/host packs as
resolved, alongside the ILLink build package. Installed SDK/reference/host packs
are recorded separately. Framework-neutral and RID-specific target metadata are
retained: a Windows DLL present in a NuGet ZIP is not automatically part of a
Linux publish. Later publish/package inspection must reconcile actual shipped
files, trimming and single-file extraction against these records.

For an existing restore, including a relocated package cache:

```powershell
$assets = @(Get-ChildItem /tmp/build/obj -Filter project.assets.json -Recurse |
    ForEach-Object FullName)
& ./scripts/ubuntu-archive/Export-DependencyMatrix.ps1 `
    -AssetsFile $assets -PackageRoot /tmp/packages `
    -OutputDirectory /tmp/matrix -Profile MariaDB -RuntimeIdentifier linux-arm64
pwsh scripts/ubuntu-archive/Test-DependencyMatrix.ps1
```

## Source families, obligations and archive inputs

The matrix records upstream metadata, not verified matching source builds. For
**each exact version**, obtain complete source, verify its declared revision,
identify generated/vendored inputs and rebuild with the archive toolchain. Record
the Ubuntu source/binary package and version, component, suite and architecture
for every replacement. If no archive input supplies the needed API/version,
package or source-build the dependency. A permissive license and a GitHub URL do
not make a prebuilt NuGet package an acceptable source-build input.

| Dependency family | Source and licensing route | Work before archive use |
| --- | --- | --- |
| grate CLI/core/providers and embedded skills/SQL | Repository source, MIT | Include complete embedded assets and original copyright/license; rebuild without prebuilt grate payloads |
| Dapper | [DapperLib/Dapper](https://github.com/DapperLib/Dapper); inspect exact version (the investigated package declares Apache-2.0) | Preserve exact-source license and applicable notices; package or source-build the matching version |
| MySqlConnector (MariaDB) | [mysql-net/MySqlConnector](https://github.com/mysql-net/MySqlConnector), MIT | Preserve exact-source copyright/license; managed protocol code does not imply a `libmariadb` runtime dependency |
| Microsoft.Extensions.* and System.* | Exact nuspec commit, often [dotnet/runtime](https://github.com/dotnet/runtime); individual package terms/notices | Match APIs/versions to source-built artifacts and review each restored package |
| System.CommandLine | [dotnet/command-line-api](https://github.com/dotnet/command-line-api), MIT | Verify matching source and notices; SDK-internal command-line code does not establish the needed external package |
| Analyzers and ILLink | Exact analyzer/linker source revisions in NuGet metadata | Include build-only inputs; installed SDK tool availability is version-sensitive |
| Notice-generation tools | Inspect the compliance audit's final publish/pack targets and build-tool requirements | Verify the final implementation against declared archive build inputs; host automation tools and an upstream SDK image do not supply Ubuntu build dependencies |
| .NET runtime/ref/apphost/SDK packs | [.NET licenses](https://github.com/dotnet/core/blob/main/license-information.md); MIT plus actual pack third-party terms/notices | Identify matching source-built packs and track bundled managed/native components for rebuilds |
| Npgsql (prospective PostgreSQL CLI) | [npgsql/npgsql](https://github.com/npgsql/npgsql), PostgreSQL license | Retain copyright/permission text; verify its source closure and archive availability independently |
| Microsoft.Data.Sqlite and SQLitePCLRaw | [dotnet/efcore](https://github.com/dotnet/efcore) MIT; [SQLitePCLRaw](https://github.com/ericsink/SQLitePCL.raw) Apache-2.0 | Preserve licenses, applicable NOTICE and copyrights; verify every native asset |
| Native SQLite package | [SQLite copyright](https://sqlite.org/copyright.html); retain the exact package text | Match actual SQLite source/version/build flags, or change and test the provider to use archive `libsqlite3-0`; system-library availability does not supply the existing NuGet native bundle |
| SQLClient, Azure, MSAL, IdentityModel | Exact source/license per package; many managed parents MIT | Review NativeInterop and SNI separately below; parents' MIT terms do not relicense children |
| Oracle | [Exact package terms](https://www.nuget.org/packages/Oracle.ManagedDataAccess.Core/23.26.400/License) | Preserve existing All/Oracle channels separately; excluding Oracle does not clear other dependencies |

Ubuntu's [.NET packaging plan](https://devblogs.microsoft.com/dotnet/whats-new-for-dotnet-in-ubuntu-2604/)
distinguishes the official archive and .NET backports PPA and describes
source-built artifacts. Probe actual suites/architectures with
[`Inspect-Archive.ps1`](../../scripts/ubuntu-archive/Inspect-Archive.ps1). An SDK
candidate does not establish that Dapper, MySqlConnector, CommandLine, the needed
Extensions assemblies or exact self-contained runtime/linker packs are usable
archive build inputs. Inspect the installed artifact feed and corresponding
archive source packages; leave unresolved mappings explicit.

## SQL Server restrictions survive removing Oracle

The SQLServer/Azure chain can restore `Microsoft.Identity.Client.NativeInterop`.
The audited 0.20.6 package has proprietary terms and a Linux x64 native
`libmsalruntime.so`. [Upstream issue #6118](https://github.com/AzureAD/microsoft-authentication-library-for-dotnet/issues/6118)
tracks its unresolved redistribution restriction. A maintainer's expectation
about redistribution is not a replacement license. These terms block assuming
that SQLServer or all-except-Oracle is a free archive variant. An arm64 target's
lack of this Linux x64 native asset does not itself establish licensing or
functionality of the managed broker chain.

Inspect the managed DLL as well as the native runtime: selecting ARM does not
establish that NativeInterop code is absent. Compare the actual license bytes
when evaluating upgrades; a newer package number is not a redistribution grant.
The function-preserving path requires authoritative applicable Microsoft terms
for the covered managed/native components. Attribution work in
[PR #925](https://github.com/grate-devs/grate/pull/925) is separate from that
clearance and must be integrated explicitly rather than assumed merged.

`Microsoft.Data.SqlClient.SNI.runtime` has separate Microsoft terms granting
conditional application redistribution, with restrictions inconsistent with
assuming a DFSG-free component. Its Windows native DLLs occur in restored package
metadata; distinguish those bytes from a Linux RID's selected output. Do not
claim Linux embeds SNI merely because its package was restored or treat
redistribution permission as a free-software license. The
[SNI terms](https://www.nuget.org/packages/Microsoft.Data.SqlClient.SNI.runtime/7.1.0/License)
section 3 require protective downstream agreements and indemnity, including an
exception for claims based solely on unmodified Distributable Code. These require
an accountable decision and delivery mechanism; notices do not accept those
obligations on the project's behalf. Windows-only SNI is a separate distribution
responsibility from the Linux archive payload.

Preserve existing authentication and networking behavior while investigating a
remedy. Microsoft's [managed-networking switch guidance](https://learn.microsoft.com/en-us/sql/connect/ado-net/appcontext-switches?view=sql-server-ver17#enable-managed-networking-on-windows)
limits that Windows switch to testing/debugging and identifies missing non-domain
Windows Authentication. A runtime switch is neither a verified equivalent
replacement nor proof that the native DLL disappeared from the artifact.

Broker-independent Unix authentication is a separate upstream/implementation
possibility, not established compatibility. Use official module separation or a
separately named provider through public registration APIs, preserving the
official Azure provider's identity checks. Before claiming equivalence, verify
the existing Entra authentication methods, supplied tokens, refresh, cancellation,
cache/tenant/cloud behavior and relevant Windows WAM/networking contracts on
real environments. Neither those tests nor vendor/legal approval are supplied by
the MariaDB source-build experiment. Redistribution permission also leaves
source-build and DFSG/Universe suitability to be assessed independently.

## Native runtime and actual package checks

Self-contained means no separate shared .NET runtime, while native OS dependencies
remain. Derive final Debian dependencies from the ELF closure (`readelf`/`ldd`,
applicable `dpkg-shlibdeps` inputs) and runtime checks, including libraries loaded
dynamically. Review glibc, libgcc/libstdc++, OpenSSL, zlib, ICU and timezone behavior
for the chosen Ubuntu suite. Do not copy version floors from another suite.

The exporter alone does not establish installed notices. The local source-package
PoC now generates them from its actual closure using the [offline notice helper](../../installers/ubuntu-source/notices/README.md),
then installs copyright, full license/NOTICE texts and a JSON inventory in the
actual .deb. The [installed verifier](../../installers/ubuntu-source/tests/README.md)
checks these files, no-shared-runtime execution and real migration/lifecycle
behavior. Keep run results tied to the exact package hashes. These checks do not
establish general legal sufficiency, archive-ready Build-Depends or sponsor approval.
