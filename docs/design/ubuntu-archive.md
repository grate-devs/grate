# Ubuntu official-archive feasibility

This investigation supports [#920](https://github.com/grate-devs/grate/issues/920).
The deliverables are a [source-package experiment](../../installers/ubuntu-source/README.md)
and a [dependency inventory workflow](ubuntu-archive-dependencies.md). The
provider-selection foundation is the still-separate [PR #910](https://github.com/grate-devs/grate/pull/910).
It must land, or its relevant changes must be carried explicitly, before using
this recipe from main. The ordinary All releases, including Oracle, retain their existing
behavior.

## Recommendation

Start with **MariaDB, amd64 and arm64, targeting Universe in the Ubuntu
development release**. Use the supported net10.0 target as the initial
source-build baseline. This avoids making .NET 11 GA an unnecessary prerequisite
for investigating the application dependencies. Self-contained, trimmed output
remains the preferred experiment; a framework-dependent package is a separate
fallback. Neither is ready for archive submission merely because an SDK can be
installed.

The first substantive obstacle is obtaining the exact application and publish
dependencies from declared, source-built inputs. An SDK package and its
source-built-artifacts package do not automatically supply Dapper,
MySqlConnector, System.CommandLine, or every requested Microsoft.Extensions
version. Upstream NuGet restoration is useful for an inventory, but its binaries
are not a substitute for an archive source-build dependency chain.

Treat the [recipe](../../installers/ubuntu-source/README.md) as an experiment,
not as an upload candidate. A failed, isolated offline restore is an actionable
result. Do not satisfy it by mounting a developer package cache, restoring from
NuGet.org, lowering runtime security minimums, or downloading a grate release.
Binary-package installation and lifecycle claims require a successfully built
artifact from this recipe; existing upstream-package results cannot establish
them.

## Release, toolchain and submission route

Ubuntu **27.04 (Tenacious T-Rex)** is the development target. The release team
[opened it on 30 October 2026](https://lists.ubuntu.com/archives/ubuntu-devel/2026-October/043674.html).
Its [schedule](https://documentation.ubuntu.com/release-notes/27.04/schedule/)
lists Feature Freeze/Debian Import Freeze on 25 February 2027 and release on
22 April 2027. Recheck dates before arranging sponsorship.

Use Ubuntu **26.04 LTS (Resolute)** for the initial archive-toolchain experiment
and separately repeat it in Tenacious before submission. The current source
pins .NET 11 RC3 in global.json; selecting Ubuntu's supported SDK 10 outside
that directory with an explicit net10.0 target is an intentional local baseline,
as described in CONTRIBUTING.md. It does not verify net11.0. Preserve the
existing self-contained runtime floor in src/grate/grate.csproj.

Canonical's [availability table](https://ubuntu.com/developers/docs/reference/availability/dotnet/)
distinguishes archive versions from PPA-only versions. Inspect signed APT
indices for the exact suite and architecture, including SDK, targeting/apphost
packs, runtime, source-built-artifacts and their source-package versions.
Inspect the artifact tarball contents; its existence is insufficient. The
[26.04 .NET plan](https://devblogs.microsoft.com/dotnet/whats-new-for-dotnet-in-ubuntu-2604/)
expects .NET 11 in the **dotnet/backports PPA** at GA; that is not an archive
publication promise. Repeat the checks after .NET 11 GA, including SDK compatibility
with the project's updated pin. A prerelease package with the right major
version does not satisfy an RC3/GA SDK requirement.

Repeat the index probe with PowerShell and Docker, saving observations outside
git. This queries packages without installing them; amd64 execution on an arm64
Docker engine uses emulation:

```powershell
pwsh scripts/ubuntu-archive/Inspect-Archive.ps1 -Suite tenacious -Architecture arm64 -OutputDirectory /absolute/path/evidence/tenacious-arm64
pwsh scripts/ubuntu-archive/Inspect-Archive.ps1 -Suite tenacious -Architecture amd64 -OutputDirectory /absolute/path/evidence/tenacious-amd64
```

For repeatability, pass `-UbuntuImage ubuntu:26.04@sha256:<recorded-digest>`;
the output records the image identity, configured archive sources and candidates.

Keep raw `apt-cache policy/show`, source indices, image digests, package
inventories and command logs in a linked review/CI artifact. An availability
observation has a suite, pocket, component, architecture and date; do not turn
one into an unqualified claim about all Ubuntu releases.

The [new-package process](https://ubuntu.com/project/docs/how-ubuntu-is-made/processes/new-packages/)
recommends Debian first, or an Ubuntu needs-packaging request and sponsorship
where appropriate. Link the existing [Debian ITP #996053](https://bugs.debian.org/cgi-bin/bugreport.cgi?bug=996053)
when coordinating; it records intent, not a current successful Debian build.
For Ubuntu, prepare a source upload for sponsor review and NEW processing by
Archive Admins. Universe is the proposed component; Main inclusion is a
different process. No sponsor or Archive Admin has approved this design, and no
contact or upload is performed by these scripts.

For older LTS releases, first establish the package in the development release,
then investigate [official Backports](https://ubuntu.com/project/docs/how-ubuntu-is-made/processes/backports/)
with builds and tests on each target LTS and the relevant dependency chain.
Backports and a Launchpad PPA are distinct channels. The archive's
[backports pocket has no Security Team update guarantee](https://documentation.ubuntu.com/project/how-ubuntu-is-made/concepts/package-archive/).
For 24.04, reassess its available .NET 10 inputs rather than assuming the
26.04 artifact feed is portable. For 22.04, .NET 10 is listed as PPA-only in the
availability reference; that route does not prove an official-archive build.
Debian main needs its own SDK/bootstrap and dependency investigation.

## Provider variants and identities

The current profiles are All, MariaDB, SQLite and SQLServer. All includes Oracle.
Do not describe it as a free archive variant. Use the inventory workflow to
resolve the exact target/RID graph and distinguish restored packages from files
actually selected for publication.

| Variant | References and compiled registration | CLI/default changes | Proposed Debian identity and decision |
| --- | --- | --- | --- |
| MariaDB | grate.core + grate.mariadb/MySqlConnector; exclude SQL/Azure, PostgreSQL, Oracle and SQLite references | Existing MariaDB-only help, completion, validation and default; test omitted-provider rejection | `grate-mariadb`; initial experiment |
| SQLite | grate.core + grate.sqlite and Microsoft.Data.Sqlite/SQLitePCLRaw native closure | Existing SQLite-only behavior | `grate-sqlite`; evaluate system SQLite versus embedded e_sqlite3 and its complete source provenance |
| SQLServer | grate.core + grate.sqlserver, SqlClient and Azure authentication closure | Existing SQLServer-only behavior | `grate-sqlserver`; hold pending licensing/source assessment of managed and native authentication components, including ARM |
| PostgreSQL | Add a PostgreSQL profile and conditional project reference; existing POSTGRESQL_ONLY registration branches are not a selectable profile | Add build validation/package readme/identity and verify sole-provider help, completion, rejection and default | `grate-postgresql`; future implementation, inventory is an assessment until that profile exists |
| All except Oracle | Add a separate profile constant; include four references/registrations and SQL/Azure only where required; exclude Oracle project and Pkcs dependency if no remaining caller requires it | Multi-provider help/completion/parser must restrict to the compiled set; preserve SQLServer default; reject Oracle before migration initialization | `grate-free` is a provisional name, not a license claim; blocked by SQLServer's unresolved dependencies |
| All (including Oracle) | Retain the existing profile, references, package ID and external distribution channels | Preserve existing defaults and behavior | Existing `grate`; outside the proposed Universe experiment |

The package owns `/usr/bin/grate`; variants sharing that path cannot co-install.
Declare mutual Conflicts/Replaces, including the existing `grate` package and
any other shipping variant. `Provides` should describe a stable virtual
capability only if consumers need one; it must not misrepresent a slim package
as supporting every provider. A future variant must update older variants'
conflict relationships as needed. Review the package namespace with the sponsor
before submission.

For switching, remove the previous command package and install the new variant
using the package manager, then rerun against the same external database and
skill destination. Do not use force-overwrite or delete user data to resolve a
file conflict. Changing package identity is separate from migration identity:
script hashes, history schema and user database contents remain compatible.

## Embedded runtime and security ownership

[Debian Policy 4.13](https://www.debian.org/doc/debian-policy/ch-source.html#embedded-code-copies)
prefers packaged libraries over convenience copies and separate packaging where
possible. **Interpretation requiring sponsor confirmation:** a bundled .NET
runtime and trimmed managed libraries need an explicit review under that
policy. Single-file layout or an MIT top-level license does not settle it.
This investigation neither declares bundling categorically forbidden nor assumes
an exception. Ask which Ubuntu .NET source-built inputs and bundled artifacts
the sponsor/Archive Admin will accept, and how fixes must be coordinated.

Microsoft's [deployment documentation](https://learn.microsoft.com/en-us/dotnet/core/deploying/)
explains that self-contained output includes the runtime, still needs OS-native
dependencies, and needs application republication to update that runtime.
[Single-file documentation](https://learn.microsoft.com/en-us/dotnet/core/deploying/single-file/overview)
also describes runtime/native extraction and per-architecture output. Trimming
does not erase input licensing or update obligations. Review the [.NET license
and third-party notice model](https://github.com/dotnet/core/blob/main/license-information.md)
for the exact source/runtime version, including the executable host.

Before accepting maintenance responsibility, assign named owners to these roles:

| Owner role | Required maintained record and action |
| --- | --- |
| grate packager | Record source revisions, Debian versions, SDK/runtime/host/linker packs, managed/native package hashes, build inputs and license/NOTICE files for each profile/RID; attach provenance to every output |
| dependency maintainers | Supply matching sources and archive packaging, monitor advisories for the resolved graph and bundled native components, and communicate fixes to the packager |
| security rebuild owner | On an embedded-runtime or library fix, patch/rebuild every affected package/architecture/supported Ubuntu suite, rerun installed-artifact checks, and request sponsored security/update uploads; system .NET updates alone leave embedded copies unchanged |
| lifecycle/test owner | Maintain migration, rerun, upgrade/switch/remove/purge and skill tests against the exact rebuilt package; preserve independent database assertions and results |

For SQLite, track e_sqlite3 and its own source revision/configuration separately
from the managed wrapper. For SQL Server, track actual Linux native payloads
separately from Windows-only SNI files in the restored NuGet package. An upstream
[NativeInterop licensing issue](https://github.com/AzureAD/microsoft-authentication-library-for-dotnet/issues/6118)
requires resolution using the exact selected package/license; a maintainer's
informal expectation is not a corrected redistribution grant. Coordinate all
license text collection and open questions with the NuGet compliance work.

The [SQL Server dependency assessment](ubuntu-archive-dependencies.md#sql-server-restrictions-survive-removing-oracle)
also separates NativeInterop grants, Windows SNI's conditional redistribution
terms, actual managed/native payload inspection and function-preserving remedies.
Retain the current auth/network feature contract: switching networking modes,
removing broker support or requiring external tokens is not established parity.
A separately registered Unix provider or official upstream module split needs
its own implementation and real authentication verification. A redistribution
grant does not by itself establish free-archive suitability.

## Installed-artifact verification after an offline build

Retain the checks below as acceptance gates, not as claims about unbuilt output.
Use a disposable Ubuntu environment with native runtime dependencies but **no
shared .NET installation**, no mounted SDK/NuGet cache, and an empty extraction
directory. Inspect dpkg registration, package file list and ELF/native imports;
include dlopen dependencies that shlibdeps cannot discover automatically.
`libicu-dev` is not an appropriate generic runtime dependency. Resolve ICU,
OpenSSL, libc, libgcc, libstdc++, zlib and any provider-native requirements for
the target suite, and declare actual runtime packages plus generated shlibs
dependencies.

1. Install the exact package, check its dpkg version and executable version in
   `grate --help`, then install the bundled skill. Here `--version` selects the
   database migration version, not the application version.
   Check selected-provider default, explicit selection and omitted-provider
   failures before a database connection can be attempted. Inspect publish
   metadata/component records for absent provider clients, not just help text.
2. Run the installed MariaDB command against a disposable real server with a
   one-time migration inserting a known row. Query the row and grate script
   history/error tables with an independent MariaDB client. Rerun with default
   then explicit provider; verify the data and one-time history did not grow
   and no errors were recorded. Test the next version with an additional script.
3. Install a second Debian version with the same command identity, verify version
   ordering and dpkg upgrade, and run the new migration with the same database.
   Attempt conflicting-variant co-installation and verify rejection preserves
   the installed command. Exercise an explicit remove/install variant switch.
4. Remove then purge, verify all package-owned files disappear, and independently
   verify the external migration database, user scripts, installed skill and
   selected output directory survive. Packaging must not own those user paths.

Reuse [#881](https://github.com/grate-devs/grate/issues/881)'s package lifecycle
work and [#910](https://github.com/grate-devs/grate/pull/910)'s independent
MariaDB checks. Neither is evidence that a new source-package artifact passed.
The SQLite lifecycle verifier needs a real MariaDB fixture/assertions when
used for this profile. Report native arm64 and emulated amd64 execution
separately; a successful cross-publish is not a runtime test. Other RIDs and
the .NET 8/9/11 targets remain outside a net10 archive experiment.

## Alternatives and bounded follow-ups

| Delivery | Benefit | Remaining requirement |
| --- | --- | --- |
| Self-contained Universe | Desired installed command without shared .NET | Offline source chain, bundle-policy review, notices, native dependencies, ongoing embedded-runtime rebuilds and all artifact gates |
| Framework-dependent Universe | Can consume system runtime security servicing | Still needs application sources/dependencies/notices and archive builds; declare runtime dependency, disable self-contained trimming/bundling, install the full app payload and test runtime roll-forward |
| Self-contained GitHub / PPA | Existing binaries or flexible external build inputs | License obligations and embedded-runtime maintenance still apply; does not establish official archive acceptance |
| Snap | Separate application delivery and confinement options | Own packaging/review/update work; not a Universe source-package result |

The next bounded work items are:

- Package or justify every missing MariaDB build dependency from matching
  sources; prove offline restore, build, publish and binary-package creation
  in a clean distribution environment with declared Build-Depends.
- Recheck .NET 11 after GA and security floors in Tenacious. Decide with a sponsor
  whether net10 or net11 is the maintained archive baseline and whether runtime
  bundling is acceptable; record actual feedback rather than infer approval.
- Complete notices/copyright from actual publish inputs and inspect the installed
  package; run the installed-artifact/lifecycle gates above on arm64 and amd64.
- Implement PostgreSQL and a restricted multi-provider profile only after their
  dependency/licensing assessment. Removing Oracle alone is insufficient.
- Once those blockers are resolved, prepare lintian, reproducible-build and
  autopkgtest results and a source upload for sponsorship/NEW; investigate LTS
  backports separately.

Attach each run's logs, generated dependency/license matrices and package
outputs to its review/CI record. This document and the recipe remain reusable;
point-in-time evidence belongs outside git. Until those gates pass, keep #920
open and describe the preferred official-archive/self-contained result as
unachieved.
