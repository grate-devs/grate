# WinGet identity migration (#800)

The correction passes the disposable Windows CI matrix described below. Nothing has been
submitted to winget-pkgs, released or merged. `grate-devs.grate` is a proposed new
package, not an alias. Historical `erikbra.grate` manifests remain unchanged.

## Supported transition

For an existing MSI, install directly through the new ID. The corrected MSI
performs the legacy major upgrade inside its installation transaction. WinGet
records the resulting identity under the new ID from the start:

```powershell
# After the new ID and corrected stable release have been accepted/published:
winget install --id grate-devs.grate --exact --source winget --architecture x64 --installer-type wix
winget list --id grate-devs.grate --exact --source winget
# Subsequent versions use ordinary upgrades through the new ID:
winget upgrade --id grate-devs.grate --exact --source winget
```

Use the architecture of the existing installation. There is no `--force`, manual
MSI uninstall or private tracking database edit in this transition. The CI test
requires the legacy product to disappear, only the new exact ID to match, export
to choose the new ID, and a later new-ID upgrade to succeed. The installed path,
command and external migration data are preserved. Native tests independently
verify rollback restores the legacy product if the new installation fails.

A direct `winget upgrade --id grate-devs.grate` cannot discover an installation
whose identity is still the legacy package. Its rejection must preserve the old
installation; `install` is the deliberate replacement command above.

Portable ZIP identity is tied to package ID and source. ZIP installations use an
explicit uninstall/install transition:

```powershell
winget uninstall --id erikbra.grate --exact --source winget
winget install --id grate-devs.grate --exact --source winget --architecture x64 --installer-type zip --scope user
```

Tests require successful commands by exact ID, a single correct command link,
exclusive new-ID correlation/export, a subsequent new-ID upgrade and preserved
external SQLite migration data. ZIP manifests omit `Scope`: WinGet controls
portable scope through the command/settings. CI selects and verifies per-user
registration.

## Why an old-ID publisher bridge is not proposed

The official
[publisher-transition recipe](https://github.com/microsoft/winget-pkgs/blob/master/doc/FAQ.md#what-should-i-do-if-a-package-is-being-published-by-a-new-publisher)
was tested with an old-ID bridge containing the old publisher and no product or
upgrade codes. The native payload upgrade works, but WinGet 1.29.380's
[RecordInstall](https://github.com/microsoft/winget-cli/blob/v1.29.380/src/AppInstallerCLICore/Workflows/InstallFlow.cpp#L958-L986)
adds detected new ARP codes to the tracking manifest under the old ID. Both
exact ID queries can then match one installed product.

An uninstall after that upgrade did not remove the alias in the observed run.
The installed-version wrapper retains its ARP identifier while substituting the
tracking source. The uninstall flow records that version first, deduplicates by
source, and the tracking catalog searches the ARP identifier instead of the old
package ID. See the pinned
[wrapper](https://github.com/microsoft/winget-cli/blob/v1.29.380/src/AppInstallerRepositoryCore/CompositeSource.cpp#L292-L319),
[uninstall flow](https://github.com/microsoft/winget-cli/blob/v1.29.380/src/AppInstallerCLICore/Workflows/UninstallFlow.cpp#L442-L461)
and [catalog removal](https://github.com/microsoft/winget-cli/blob/v1.29.380/src/AppInstallerRepositoryCore/PackageTrackingCatalog.cpp#L292-L308).
`repair` and `install --force` do not provide a supported tracking transfer.

Therefore preparation emits only the new ID and keeps old historical versions
unchanged. The code-free bridge remains a diagnostic test fixture; its test runs
last, because it contaminates the old tracking record with the new family. It
is not a publishing output. A previously contaminated tracker remains a client
limitation; it is not repaired by this package change. Do not upgrade through a
corrected old-ID bridge before following the supported transition above.

## MSI compatibility contract

Historical MSIs used fixed ProductCode
`{E281998A-D8A2-4926-AAA3-066EFA4B2E74}` across versions/architectures and random
UpgradeCodes per build. The corrected MSI uses deterministic UUIDv5 ProductCodes
per version and canonical architecture, a new stable UpgradeCode family per
architecture, and actual Manufacturer/ARP Publisher `grate-devs`. See
`../msi/identity-contract.json`.

| Resource | Preserved contract |
| --- | --- |
| MSI context / privileges | per-user / limited |
| Install directory | `%LOCALAPPDATA%\erikbra\grate` |
| Registry marker | `HKCU\Software\Microsoft\erikbra\grate`, `installed=1` |
| Main executable component | `{C544280E-4F9B-443D-BE6D-4A82CFEE3723}` |
| PATH component | `{E7507A5D-D78E-4082-BD75-986A11F54E68}` |
| Command | `grate` |

A native immediate custom action uses supported Windows Installer APIs to
validate the fixed legacy ProductCode in the current user's contexts, including
name, publisher, installed state and version. It adds only that verified product
to standard major-upgrade removal. Historical random UpgradeCodes need not be
known or copied into new manifests. The other new architecture family is rejected
before it can overwrite the shared path. New-family downgrades are blocked.

Major-upgrade removal runs after InstallInitialize, within rollback. Tests inject
a separate late-failure MSI and require ordered removal/failure/rollback events,
then independently check restored registration, payload hash, context and data.
No Installer-owned registry data is relocated or deleted by custom code.

MSI generation requires Visual Studio C++ x64/ARM64 tools and the Windows SDK in
addition to pinned WiX 3.14.1. The custom action uses `/MT`, so the installed
application does not need a separately installed Visual C++ runtime.

### Prerelease MSI policy for release integration

The builder accepts numeric `-Version` and full SemVer `-ReleaseVersion` (defaulting
to the numeric version for stable callers). The actual executable's ProductVersion,
excluding informational `+build` metadata, must equal ReleaseVersion; passing only
the numeric core for a prerelease executable is rejected. The full release string
is recorded in MSI property `GRATE_RELEASE_VERSION` and determines ProductCode.
Stable ProductCodes and both architecture UpgradeCodes remain unchanged.

Windows Installer's ProductVersion remains a numeric triplet. Different products
with the same numeric version require explicit uninstall/reinstall, including
rc-to-rc, rc-to-final and final-to-rc. The native action enumerates the installed
family independently of FindRelatedProducts and refuses a different ProductCode
with equal ProductVersion before removal can run. This same-core rule also covers
the legacy fixed-code product; it does not authorize republishing/replacing an
existing stable version. The current ProductCode is excluded to preserve ordinary
repair. Upgrades to a higher numeric version retain transactional MajorUpgrade;
the existing downgrade guard remains active. The installer does not compare
SemVer prerelease labels.

`Test-PrereleaseMsiPolicy.ps1` is a small Windows policy check using isolated,
framework-dependent probe apphosts. It checks actual MSI metadata, rejection of
core-only authoring, three same-core refusals with original registration/payload
preserved, explicit uninstall/reinstall, higher-core upgrades and external data.
It copies authoring into its evidence directory so it cannot overwrite a release
MSI in `installers/msi/tmp`. Probe fixtures are never release artifacts. The
manual `msi-prerelease-policy.yml` workflow runs this check on x64 and ARM64;
this is separate from full application and WinGet lifecycle matrices.

[Native prerelease policy run 41411152047](https://github.com/grate-devs/grate/actions/runs/41411152047)
passed both architectures at test commit
`20ca2dd97b8fb5f41dd440d8df9c30235bdda759`, using production policy commit
`c83a2754b24e6bd3057c43283cf0cf4a2e9ae484`. Each job built and inspected five
actual probe MSIs, required three refusals to return 1603 with the native
same-core message, and completed six successful install/upgrade/uninstall
operations. Ten inventory snapshots per architecture show one current-user
context-2 product at a time, the original registration after each refusal,
and no product after final uninstall. Payload hashes and external data are
checked throughout. The first run failed before installation because the probe
passed a mixed-separator MSI path; the test-only path normalization fix did not
change production code. Pure C++ policy cases also reject equal-core legacy
replacement; that additional legacy boundary was not separately runtime-tested.
The earlier full WinGet/native rollback matrices remain historical evidence for
the stable paths described below, rather than a claim that this small probe
repeated all application, rollback and source checks.

## WinGet scope workaround

WinGet 1.29.380 can report this per-user MSI as Machine because its ARP inventory
derives scope from the registry hive. Native MSI APIs instead report the current
user's installation context. See
[winget-cli #3011](https://github.com/microsoft/winget-cli/issues/3011).

Corrected MSI manifest nodes omit optional `Scope`. The pinned client's
[installed-scope comparator](https://github.com/microsoft/winget-cli/blob/v1.29.380/src/AppInstallerCommonCore/Manifest/ManifestComparator.cpp)
permits unspecified scope during subsequent upgrades. Actual MSI authoring stays
per-user/limited; tests require exactly one current-user instance and no machine
instance through MsiEnumProductsExW/MsiGetProductInfoExW.

An explicit `--scope user` selector rejects this unspecified MSI manifest in the
observed client (0x8A150010), leaving no installation. Omit that selector for MSI,
as in the supported command above. Required user-scope settings can impose the
same client limitation. Portable ZIP commands can still select user scope.

## Preparation and CI

`Create-Installer.ps1` requires a published stable three-part release and its
actual five uploaded assets: three Windows self-contained ZIPs (x86/x64/ARM64)
and two MSIs (x64/ARM64). Drafts, prereleases, missing assets, unexpected URLs and
MSI digest mismatches are rejected. It never submits or overwrites output.

The default mode inspects actual MSI metadata and permits only the historical
old identity. Corrected or unrecognized identities require `-PrepareMigration`;
otherwise new family codes could permanently pollute old historical manifests.
Migration mode verifies the corrected MSI identity, per-user properties, version,
architecture, digest and stable family, then emits only `grate-devs.grate`.

```powershell
# Historical published release; old-ID preparation only:
./installers/winget/Create-Installer.ps1 -version 2.1.6
# Once a corrected stable release exists; VERSION is not a CI fixture:
./installers/winget/Create-Installer.ps1 -version VERSION -PrepareMigration -outputDirectory ./candidate
```

The opt-in Windows lifecycle workflow builds test-only 2.1.7/2.1.8 artifacts from
source. It pins WinGet 1.29.380, preserves candidate run/source/script provenance
and supports isolated HTTPS REST and preindexed SQLite sources.
Candidates may be reused without rebuilding the MSI when only test scripts change.
The REST source returns every matching strong identity. It advertises normalized
name/publisher pair search as unsupported, rather than approximating it with a
misleading name-only match. This is an explicit REST fixture capability, not a
claim of equivalence with the community source's SQLite implementation.

### Preindexed source and public-origin checks

Select `source_type=PreIndexed` to exercise `Microsoft.PreIndexed.Package`.
The harness downloads checksum-pinned `Microsoft.WindowsPackageManager.Utils`
1.29.380 and calls its native index APIs. Microsoft code performs index creation,
normalization, consistency checks, manifest stream hashing and packaging
preparation; the fixture does not manufacture SQLite rows or correlation results.
Each version becomes one complete singleton YAML stream, avoiding the V2
index's multi-file manifest stream-hash ambiguity. Both IDs and all four versions
are present from the beginning in the private-origin case. The index is immutable
throughout that run; the rejected bridge diagnostic remains REST-only.

Windows SDK tools package and sign V2 (`source2.msix`, SQLite 2.0) and fallback
V1 (`source.msix`, SQLite 1.7) sources with a disposable certificate. A temporary
registration determines the actual source package family and is removed before
WinGet adds the source. WinGet must then fetch/register the source itself over
HTTPS. The server also serves the native V2 compressed version-data files and
unchanged installer assets. Evidence includes source exports, native index logs,
source packages, indexes, manifests, hashes, utility/SDK provenance and HTTP logs.
Certificate private keys remain outside uploaded evidence and trust is removed
during cleanup.

Select `public_baseline=true` to install historical 2.0.0 with the genuine
`--source winget` before adding the candidate source. This is the historical
version currently present in the public catalog; 2.1.6 is tested separately through
the private catalog. The test preserves the public source and WinGet tracking,
asserts the old ID's public origin in export before candidate addition, and checks
that the public source's URL/type/identifier remain unchanged. The private
candidate catalog contains only the new ID in this scenario, avoiding a duplicate
old package in a second source.

After the rejected direct new-ID upgrade, the supported transition, and the next
new-ID upgrade, assertions inspect both source-filtered and unfiltered exact-ID
queries plus global export. This catches an old public tracking alias that would
be invisible when looking only at the candidate source. MSI still upgrades
transactionally; portable ZIP explicitly uninstalls the public old ID first.
Actual payload, native context, command, user data and strict uninstall checks
remain active.

For example, reuse the verified candidate artifacts without rebuilding them:

```powershell
gh workflow run winget-lifecycle.yml --ref feat/800-winget-migration -f candidate_run_id=41363831167 -f cases=all -f direct_msi=false -f source_type=PreIndexed -f public_baseline=false
gh workflow run winget-lifecycle.yml --ref feat/800-winget-migration -f candidate_run_id=41363831167 -f cases=all -f direct_msi=false -f source_type=PreIndexed -f public_baseline=true
```

`direct_msi=false` reuses the independent major-upgrade/rollback evidence below;
it does not skip the actual MSI installations performed through WinGet. `cases=x64`
provides a two-job ZIP/MSI bootstrap check; `all` retains all five architectures/
installer combinations. Public origin is reported separately from public
destination: the new package still comes from a private source with its own
identity, even when its source implementation is the same as the public catalog.

Native tests isolate read-only MSI inventory/metadata from the process that
waits for installation. A supervised child has an outer deadline, and diagnostic
files survive failure. Source queries are skipped after a native failure so an
unfinished MSI transaction cannot block evidence retention.

Checks cover actual installed payload SHA256/file version, `--help`, user PATH,
MSI context, SQLite migration/rerun, a single history row, no migration errors,
external data preservation, strict exact-ID uninstall and cleanup. `grate
--version` sets a database migration version and is not used as a CLI version
probe. Artifacts retain raw MSI/WinGet logs, native inventories, commands,
manifests, exports and results for seven days.

## Evidence and limits

The additional checks passed at script commit
`27458d4065010cfd7f8e520c1d8bb615205dd514`, using the same immutable candidates and
unchanged MSI/application inputs as the earlier lifecycle run:

| Source and baseline | Verified result |
| --- | --- |
| [Private SQLite, run 41402119958](https://github.com/grate-devs/grate/actions/runs/41402119958) | ZIP x86/x64/ARM64 and MSI x64/ARM64: both IDs in one native SQLite 2.0 catalog, historical installs, supported ID transition, exclusive new-ID correlation/export, subsequent upgrade, data preservation and strict uninstall |
| [Public origin to private SQLite, run 41402122968](https://github.com/grate-devs/grate/actions/runs/41402122968) | All five combinations: actual public 2.0.0 install, public source/tracking preserved, new-ID transition, all-source and individual-source correlation, global export, next upgrade, data preservation and strict uninstall |

Both matrices require the actual registered candidate source type, family and
URL to match the prepared source. All five public-origin jobs fetched
`source2.msix` over HTTPS and opened a native SQLite 2.0 index; the public source
kept its original Microsoft identity. Independent review checked the 120 exact
query results, 20 stage exports, five pre-candidate exports, source package/index
and manifest hashes, native registrations and 30 successful migration invocations
in the public-origin matrix.
The private-origin matrix was independently checked for both indexed IDs/all
four manifest streams, real V2 requests, exclusive exports, both historical MSI
replacement routes on x64/ARM64 and 52 successful migration invocations.

[Preparation run 41402119754](https://github.com/grate-devs/grate/actions/runs/41402119754)
passed at the same script commit, including the existing preparation/native
compilation checks, 20 correlation/export checks (including deliberately wrong
queries, aliases and source identities), five singleton conversion cases and the
static-source path suite. The five static-source cases also passed locally.
The earlier x64 public-origin REST and private SQLite bootstrap runs
[41401625759](https://github.com/grate-devs/grate/actions/runs/41401625759) and
[41401780301](https://github.com/grate-devs/grate/actions/runs/41401780301) passed;
the full matrices above are the final source-test evidence.

[Final Windows lifecycle run 41365480749](https://github.com/grate-devs/grate/actions/runs/41365480749)
passed all five jobs with script commit
`324de4951ca4f556afc0f048b8f690a0862563bd`. It reused immutable test candidates from
[build run 41363831167](https://github.com/grate-devs/grate/actions/runs/41363831167),
source `315bf65fb191c4db40ccd47e4f48e1bccda195e4`. All three candidate build jobs
succeeded before that superseded run was cancelled. MSI authoring, native action,
identity contract and application/build inputs are unchanged between those
commits; later changes concern verification and proposal preparation.

| Job | Verified result |
| --- | --- |
| [ZIP x86](https://github.com/grate-devs/grate/actions/runs/41365480749/job/125024628236) | Same-ID upgrade, explicit ID transition, exclusive query/export, subsequent new-ID upgrade, data preservation and strict uninstall |
| [ZIP x64](https://github.com/grate-devs/grate/actions/runs/41365480749/job/125024628275) | Same assertions, executing the x64 payload |
| [ZIP ARM64](https://github.com/grate-devs/grate/actions/runs/41365480749/job/125024628062) | Same assertions, executing the native ARM64 payload |
| [MSI x64](https://github.com/grate-devs/grate/actions/runs/41365480749/job/125024628318) | Both historical versions: native major upgrade, rollback restoration, next family upgrade and downgrade refusal; direct new-ID install, exclusive query/export, next WinGet upgrade, fresh install and strict uninstall |
| [MSI ARM64](https://github.com/grate-devs/grate/actions/runs/41365480749/job/125024628336) | Same native/source assertions; additionally rejects the other architecture family with its original payload/context/data preserved |

Both MSI jobs schema-validated the two new-ID manifest sets and passed the
supervisor's real successful/blocked-process contract tests. Native inventories
show current-user context 2, installed state 5 and assignment type 0, without a
machine instance. Both diagnostic old-ID bridge upgrades retained an old-ID
tracking alias, so the final proposal does not emit that bridge.

[Preparation run 41365481067](https://github.com/grate-devs/grate/actions/runs/41365481067)
passed 32 helper contract cases, 22 changed-and-rejected LF/CRLF correlation
mutations, four lifecycle catalog cases, MSI authoring/identity checks, actual
historical stable-release inspection/refusal and MSVC compilation for x64/ARM64.
The local HTTPS protocol suite passed 14 cases. Independent review checked the
actual x64/ARM64 registration, command, rollback, payload and data evidence.

Artifacts retain raw MSI/WinGet logs, native inventories, manifests, commands,
exports, provenance and result JSON for seven days. Candidate versions remain
unpublished fixtures. Community acceptance and repetition with actual published
candidate artifacts and the new ID from `--source winget` remain external
requirements; these are distinct from the public-origin checks described above.
Historical 1.2.0 and enterprise managed-user/machine installations have not been
runtime-tested. A tracker already contaminated by a corrected old-ID bridge is
an unresolved client limitation, outside the supported migration route.
No upstream submission, public release or merge was performed.
