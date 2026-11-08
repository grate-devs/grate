# Offline package notices

`Generate-Notices.proj` runs under the declared Ubuntu .NET SDK after the real
restore and publish. It needs no PowerShell or additional NuGet package at build
time: its C# tasks compile with MSBuild's Roslyn task factory and the SDK's JSON
assembly. The source recipe invokes it with the selected MariaDB/net10/RID and
installs its generated notices and inventory in the actual Debian package.

The helper reads every actual `src/**/obj/project.assets.json`, including build
and download dependencies. It also queries the project's
`ResolveFrameworkReferences` for **RuntimePack, AppHostPack and TargetingPack**.
Ubuntu can install these packs directly under `/usr/lib/dotnet/packs`, with no
entries in NuGet's library/download lists. Each resolved installed pack is mapped
to its exact-version package in the distribution source-built artifact feed;
the helper includes that package's original license and third-party notices.
Missing exact packages, missing original license evidence, mismatched source
commits and altered cached texts fail generation.

The installed AppHostPack's regular `native/apphost` template and the feed's
template can have different build IDs/bytes despite matching version/RID. The
helper records those template hashes in `apphost-sha256.txt`. This single-file
publish uses a separate `SingleFileHostSourcePath`; the template hashes do not
identify that exact selected host input. Its precise input-byte audit remains
unverified. Host package/version licensing coverage and the final executable's
own hash are separate from this limited template comparison.
`source-built-sdk-packs.json` records the selected installed directories and feed
hashes. `ubuntu-distribution-packages.json` records the **actual installed binary
package, version, source package and source version** owning each selected pack.
Their Debian copyright files, available supplier NOTICE files, .NET's installed
license/third-party notices and referenced common-license full terms are appended
to the package notice. A dangling optional supplier NOTICE symlink is identified
in the output, rather than silently counted as read. Required pack and installed
.NET license/notice files remain mandatory. These records distinguish supplier
source-build provenance from a reproducibility claim.

`sources.json` and `text/` are immutable original-license evidence, not package
binaries or execution logs. They cover the actual source-built dependency
baseline. Each entry identifies the exact nuspec repository commit, original
source URL and SHA-256. Source-code changes or a different SDK/dependency version
require rechecking that evidence. In particular, the original Dapper
`License.txt` contains its copyright and logo terms but links to Apache-2.0;
the cache adds the **full Apache-2.0 terms** even when the package already contains
that file. MySqlConnector's original MIT copyright/license is retained. Ubuntu's
source-built .NET package metadata identifies its monorepo revision, whose
original MIT license is cached; package-specific third-party notices are also
preserved.

`GenerateDependencyNoticesTask.cs` and `LicenseTask.targets` were selectively
reused from [compliance PR #925](https://github.com/grate-devs/grate/pull/925),
commit `7c47b75` (the same grate repository's MIT license). The local engine adds
validated cache supplementation even when an original license file is present,
and appends separately collected distribution license evidence. The full audit
PR and its global publish hooks are not imported. The helper is limited to this
experimental Ubuntu source package.

The inventory conservatively includes build-only and source-package licensing
material. Listing it does not mean that every component is shipped in the
trimmed binary. The output supports package review; it does not constitute
archive acceptance or a legal opinion.

After a completed offline restore/publish, verify the actual closure with:

```powershell
pwsh installers/ubuntu-source/notices/Test-Notices.ps1 `
    -StagedDirectory /tmp/grate-source-package-attempt
```

The check mounts the restored source read-only and uses temporary helper/output
directories. It verifies original/full license text, runtime/ref/apphost/linker
coverage, pack third-party notices, distribution evidence and both host hashes.
It then deliberately changes a cached Apache license and removes the source-pack
feed; each must fail for the intended reason. Docker networking stays disabled.
