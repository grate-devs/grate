# Dependency licenses and redistribution

grate's own source remains MIT-licensed. Bundled dependencies retain their own
licenses. An MIT declaration for grate, an SBOM, or an SPDX expression alone does
not grant redistribution rights for every binary in a release.

## Reproduce the inventory

Restore the solution with the SDK in `global.json`. The audit/update entry points
use PowerShell 7. Normal publish/pack use a native MSBuild task with the SDK's
existing JSON library and require no additional build-time package or PowerShell
installation. Both paths call the same notice-generation engine.

```powershell
dotnet restore grate.slnx
$assets = Get-ChildItem -Path src,unittests -Filter project.assets.json -Recurse -Force |
    ForEach-Object FullName
./scripts/licenses/Export-DependencyLicenses.ps1 `
    -AssetsFile $assets `
    -OutputDirectory artifacts/dependency-licenses
```

The JSON inventory records exact restored package versions, original metadata,
source revisions, package hashes where provided by NuGet, full-text hashes, and
product/test/example and direct/transitive project contexts. Download dependencies
such as .NET runtime packs are included. Restore examples independently and add
their assets files when auditing examples. Record any failed restores separately;
do not present an incomplete inventory as complete. A declared central package
version that no project references is not a restored dependency.

This is a dependency graph inventory, not a claim that every restored asset is
redistributed. Inspect the final published payload and the selected RID when
deciding which grants apply. In particular, library NuGet packages generally
declare dependencies; the tool, standalone binaries and installers copy them.
Test-only and analyzer packages must remain distinct from shipped product code.

Normal publish/pack supplies the product project's assets file, not the test
projects' graphs. Its notices conservatively cover that product restore graph
across restored frameworks; they can include build dependencies and assets for
other RIDs. The full-solution audit and source cache also cover test/example
dependencies. This is not a payload-only selection engine. Build tooling can
generate code and native/static inputs can contribute output code, so excluding
every analyzer/build package by its NuGet asset category would be unsafe. Use
actual payload and generation/linking evidence before narrowing shipped notices.

## Preserve original license texts

The exporter reads original LICENSE/COPYING/NOTICE/third-party notice files from
the exact restored packages. When a package supplies only an SPDX expression,
`scripts/licenses/sources.json` identifies original upstream license/notice texts
and their SHA256 hashes. The source cache is checked in so publishing remains
offline. Generic SPDX templates cannot replace original copyright notices.
Original texts have readable upstream-repository paths under
[`scripts/licenses/text`](../scripts/licenses/text/README.md). Different retained
variants identify a package/version, while `sources.json` keeps exact source URLs,
revisions and full hashes independently of filenames.

For a dependency update whose original license is absent:

```powershell
./scripts/licenses/Export-DependencyLicenses.ps1 `
    -AssetsFile $assets `
    -OutputDirectory artifacts/dependency-license-review `
    -AllowMissingLicenseEvidence
./scripts/licenses/Update-LicenseSources.ps1 `
    -InventoryFile artifacts/dependency-license-review/dependency-licenses.json
```

The second command fetches original source files at the nuspec's repository
revision. Review the resulting source URLs, copyright, full license terms and
any NOTICE files before committing the cache. A download is evidence, not legal
approval. Old packages with no repository revision require an explicit verified
source mapping. Microsoft.SqlServer.Server 1.0.0's mapping comes from the exact
package DLL's informational version and its PDB's SourceLink document URLs.
[`verified-sources.json`](../scripts/licenses/verified-sources.json) records these
reviewed exceptions and whether each dependency belongs to product, test or
example work. An old version number alone does not show that a package is unused.

Run the first export again without `-AllowMissingLicenseEvidence`. Missing source
texts, missing declared files, changed cache hashes and path traversal fail the
normal export. The audit-only switch records missing evidence rather than
pretending an SPDX identifier is the complete license text. Legacy packages with
only a `licenseUrl` retain that URL and receive a
`missing-license-declaration` status; they still fail normal publish/pack.

## Release contents

Publish and pack generate `THIRD-PARTY-NOTICES.txt` automatically for grate's
product projects. This contains the grate MIT text, versioned dependency license
references, original copyright and license texts, and nested third-party notices.
Identical texts are reproduced once with references from all contributing packages.

- Standalone ZIPs contain the notices alongside the executable. Keep both when
  redistributing the archive or its contents.
- Debian installs the same file in `/usr/share/doc/grate/`.
- MSI installs it beside `grate.exe`.
- Chocolatey carries it in `tools/` beside the executable and grate's own LICENSE.
- Docker copies it into `/app/` with the published payload. This concerns bundled
  NuGet/.NET content; the base image's own OS notices remain its responsibility.
- The .NET tool and grate library NuGet packages include it at package root.
- Homebrew casks and WinGet portable downloads consume the ZIP; keep its notice
  file with the downloaded payload. Source-built Homebrew publishes it into
  `libexec` using its existing .NET SDK build dependency.

Installer builders reject a payload missing its companion notice file. The file
stays outside the single-file bundle so it is accessible without executing grate.
No dependency is relicensed to MIT and no provider is removed by this mechanism.

## Restricted dependencies requiring separate decisions

### Oracle.ManagedDataAccess.Core

The exact package's [Oracle Free Distribution, Hosting, and Use Terms and
Conditions](https://www.nuget.org/packages/Oracle.ManagedDataAccess.Core/23.26.400/License)
permits redistribution of unmodified programs subject to its conditions,
including an accompanying license copy and retained notices. It treats compiling,
interpreting or configuring an otherwise unmodified program as necessary to run
it differently from modification. Consequently, `PublishTrimmed=true` alone does
not establish either a breach or compliance: verify what happened to the exact
Oracle assembly and assess any actual modification against the applicable terms.

### Microsoft.Identity.Client.NativeInterop

The [0.20.6 package license](https://www.nuget.org/packages/Microsoft.Identity.Client.NativeInterop/0.20.6/License)
contains restrictive Microsoft terms without an obvious redistribution grant.
The upstream [licensing issue #6118](https://github.com/AzureAD/microsoft-authentication-library-for-dotnet/issues/6118)
tracks this exact problem. A maintainer's belief that redistribution was intended
does not itself supply corrected terms. Preserve the exact license and determine
whether a formal applicable grant is available; do not assume the surrounding
MIT-licensed MSAL/SqlClient package grants rights to this native component.

### Microsoft.Data.SqlClient.SNI.runtime

The [7.1.0 SNI license](https://www.nuget.org/packages/Microsoft.Data.SqlClient.SNI.runtime/7.1.0/License)
expressly grants application/object-code redistribution in section 3, subject to
conditions including downstream protective terms and indemnity. Read its generic
section 5 restrictions together with that express grant. Including its license
text alone does not demonstrate that those conditions have been met.

Inspect platform exposure: this SNI package has Windows native payloads. A
transitive package reference in a Linux assets file is not proof those Windows
DLLs are in the Linux executable. NativeInterop has its own platform assets and
must be assessed separately.

### Test/build tooling

Microsoft code coverage tooling has its own package terms. Distinguish running
that tooling internally from redistributing it in a grate release or publishing
test artifacts. Review the inventory's test/build contexts instead of assuming
all Microsoft packages use MIT.

The notice-generation checks establish attribution delivery, not an unconditional
legal-compliance verdict. Record unresolved grants and downstream obligations in
the release/PR evidence. They do not authorize changing grate's license, dropping
functionality, or silently replacing a database provider.

Related work: [smaller distributions #909](https://github.com/grate-devs/grate/issues/909),
[Ubuntu archive investigation #920](https://github.com/grate-devs/grate/issues/920),
[performance and size #919](https://github.com/grate-devs/grate/issues/919).
