# WinGet identity migration (#800)

`grate-devs.grate` is the proposed new package identity, not an alias.
Historical `erikbra.grate` manifests remain unchanged. Public availability requires
a corrected stable release and separate acceptance into `microsoft/winget-pkgs`;
check that acceptance before using the public-source commands below.

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
It copies authoring into its temporary output directory so it cannot overwrite a release
MSI in `installers/msi/tmp`. Probe fixtures are never release artifacts. The
manual `msi-prerelease-policy.yml` workflow runs this check on x64 and ARM64;
this is separate from full application and WinGet lifecycle matrices.

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
`--source winget` before adding the candidate source. The harness uses 2.0.0 as
its public-origin fixture; confirm the
required version remains available before running it. Version 2.1.6 is a separate
private-catalog fixture. The test preserves the public source and WinGet tracking,
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

To reuse candidate artifacts, select their build run and a reviewed workflow ref.
Set `direct_msi=true` for the full native upgrade/rollback checks:

```powershell
$workflowRef = '<reviewed-ref>'
$candidateRunId = '<candidate-build-run-id>'
gh workflow run winget-lifecycle.yml --ref $workflowRef -f candidate_run_id=$candidateRunId -f cases=all -f direct_msi=true -f source_type=PreIndexed -f public_baseline=false
gh workflow run winget-lifecycle.yml --ref $workflowRef -f candidate_run_id=$candidateRunId -f cases=all -f direct_msi=true -f source_type=PreIndexed -f public_baseline=true
```

Use `direct_msi=false` only when separate applicable native major-upgrade/rollback
results are recorded for those candidates. It still runs actual MSI installations
through WinGet. `cases=x64` provides a two-job ZIP/MSI bootstrap check; `all` retains all five architectures/
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

## Submit a published release

Download the original release run's candidate and Windows assets into a fresh
staging directory. Match the artifact's run, attempt, source commit and tag to
the published release. If the artifact has expired, regenerate it on Windows
from that tag with `Create-Installer.ps1 -PrepareMigration` as shown above.

```powershell
$version = '<stable-version>'
$releaseRunId = '<release-run-id>'
$staging = Join-Path ([IO.Path]::GetTempPath()) ("grate-winget-" + [guid]::NewGuid())
gh run download $releaseRunId --repo grate-devs/grate --name "winget-migration-candidate-$version" --dir "$staging/candidate"
if ($LASTEXITCODE -ne 0) { throw 'Could not download the release candidate.' }
gh release download $version --repo grate-devs/grate --pattern 'grate-win-*.zip' --pattern 'grate-msi-win-*.msi' --pattern checksums.sha256 --pattern release-manifest.json --dir "$staging/assets"
if ($LASTEXITCODE -ne 0) { throw 'Could not download the published Windows assets.' }
$manifest = Join-Path $staging "candidate/manifests/g/grate-devs/grate/$version"
```

Compare the actual SHA-256 of each of the five files with `checksums.sha256`,
`release-manifest.json`, and the corresponding `InstallerSha256`. Check the
file sizes against the release inventory. Review the exact URLs, ZIP architecture
and executable path, and the MSI architecture and product/upgrade codes against
the payloads. Use the [current upstream PR checklist] and [schema guidance].
If the candidate schema differs, update the schema references and
`ManifestVersion` in all three YAML files after checking compatibility.
Revalidate the exact files going into the PR.

Enable local manifests on clean, disposable Windows machines and run
[Microsoft's validation and install checks]. Test ZIP on x86 (or x86 on x64),
x64 and native ARM64, and MSI on x64 and native ARM64. Use `zip` or `wix`
with the appropriate architecture. Repeat each install and uninstall on a
clean machine or snapshot.

```powershell
winget validate --manifest $manifest
winget settings --enable LocalManifestFiles
# MSI x64 example:
winget install --manifest $manifest --architecture x64 --installer-type wix --silent
winget uninstall --manifest $manifest --silent
# ZIP x64 example:
winget install --manifest $manifest --architecture x64 --installer-type zip --scope user --silent
$arp = 'HKCU:/Software/Microsoft/Windows/CurrentVersion/Uninstall'
$entry = @(Get-ItemProperty "$arp/*" | Where-Object {
    $_.WinGetPackageIdentifier -ceq 'grate-devs.grate' -and $_.DisplayVersion -ceq $version
})
if ($entry.Count -ne 1) { throw 'Expected one local portable registration.' }
winget uninstall --product-code $entry[0].PSChildName --silent
```

WinGet 1.29.380 can fail to find a local portable install via
`uninstall --manifest`. The product-code lookup above selects the installed
per-user ZIP registration. Use exact-ID uninstall for source-based tests.

Check that each install runs `grate --help`, deploys the expected executable
and leaves no registration or executable after uninstall. For migration before
submission, install the historical package from the public source and use an
isolated candidate source for the new ID so WinGet can track both IDs.
Use the supported transition above, substituting the candidate source for
`winget` on new-ID commands. Verify the installed payload, exact-ID list and
export, SQLite data preservation, and uninstall. The fixture workflow in the
previous section covers further lifecycle behavior such as a subsequent
upgrade. Record which test used final release bytes.

Check for an existing PR for the ID and version. Fork
`microsoft/winget-pkgs` and create a branch based on upstream `master`.
Copy only the three validated YAML files to
`manifests/g/grate-devs/grate/<version>/`. For a first submission, use the title
`New package: grate-devs.grate version <version>` and complete the upstream
checklist with links to the Windows evidence. Track the PR's automated checks
and moderator approval. Record PR merge and catalog availability separately.

After the PR merges, use a clean Windows system with the default `winget`
source. Pin the submitted version for each architecture and installer type.
Once the exact version resolves, repeat the installation and correlation
checks against the public source.

```powershell
winget source update --name winget
winget show --id grate-devs.grate --exact --source winget --version $version
winget install --id grate-devs.grate --exact --source winget --version $version --architecture x64 --installer-type wix --silent
winget list --id grate-devs.grate --exact --source winget
winget uninstall --id grate-devs.grate --exact --source winget --silent
```

[current upstream PR checklist]: https://github.com/microsoft/winget-pkgs/blob/master/.github/PULL_REQUEST_TEMPLATE.md
[schema guidance]: https://github.com/microsoft/winget-pkgs/blob/master/doc/manifest/README.md
[Microsoft's validation and install checks]: https://learn.microsoft.com/en-us/windows/package-manager/package/winget-validation

## Acceptance and coverage

Require successful results for all selected ZIP/MSI architectures and source
scenarios. Inspect actual registration, payload hashes, source identity, exact-ID
queries and exports, subsequent upgrades, data preservation and strict uninstall.
For native MSI checks, also inspect rollback restoration, same-core refusal and
cross-architecture guards. A green fixture/source check does not establish public
new-ID availability.

Before public acceptance, repeat the final candidate's schema and native
installation checks using the actual published release assets. After acceptance,
verify installation and correlation through the public `--source winget` catalog.
Private candidate catalogs and public-origin checks exercise different boundaries.
Enterprise managed-user/machine installations and historical versions outside the
selected fixtures require separate coverage if they are being claimed. Track any
unsupported client-tracking state explicitly.

Keep run IDs, source/candidate provenance, raw logs, inventories, manifests,
exports and result JSON in CI artifacts or external PR/release records. Retain
only reusable test code, configuration and migration instructions in git.
