# Source-building missing application dependencies

These experiments address the Dapper and MySqlConnector gaps in the
[Ubuntu source-package investigation](../README.md). Source acquisition and
Ubuntu builder provisioning happen before the offline builds. The scripts export
the exact source revisions recorded by the original NuGet packages, preserve
runtime C# source, record packaging changes and use fresh caches. Their local
nupkgs retain the identities needed by the PoC but are net10-only adaptations,
not official upstream releases or Ubuntu archive packages.

## Prepare the Ubuntu input feed

Provision `grate-ubuntu-source:26.04` with the [parent recipe](../README.md).
Extract its distribution-provided artifact tarball into an empty directory:

```powershell
$feed = '/tmp/ubuntu-source-feed'
New-Item -ItemType Directory -Path $feed | Out-Null
docker run --rm --pull=never --network=none --platform=linux/arm64 `
    --mount "type=bind,src=$feed,dst=/feed" grate-ubuntu-source:26.04 sh -ec `
    'tar -xzf /usr/lib/dotnet/source-built-artifacts/Private.SourceBuilt.Artifacts.10.*.tar.gz -C /feed'
if ($LASTEXITCODE -ne 0) { throw 'Archive input extraction failed.' }
```

Record the builder image, installed Ubuntu package versions and artifact-tarball
hash. Do not populate this feed from developer caches or online NuGet restores.
During dependency builds the feed is read-only and networking is disabled.

Follow the [Dapper recipe](dapper/README.md) and
[MySqlConnector recipe](mysqlconnector/README.md), using the same feed and separate
new output directories. Preserve original-build failures alongside adapted-build
results. The main adjustments remove unavailable release/versioning/analyzer
tooling. MySqlConnector also uses archive logging/DI dependencies 10.0.14 instead
of the upstream 8.x baseline; its documentation explains that compatibility limit.

## Verify the two local packages

Provision the disposable database image before the test:

```powershell
docker pull --platform linux/arm64 mariadb:10.4
if ($LASTEXITCODE -ne 0) { throw 'Database fixture provisioning failed.' }
pwsh -NoProfile -File installers/ubuntu-source/dependencies/Test-BuiltLibraries.ps1 `
    -DapperPackage /tmp/dapper-archive/packages-built/Dapper.2.1.89.nupkg `
    -MySqlConnectorPackage /tmp/mysqlconnector-ubuntu-net10/packages/MySqlConnector.2.6.2.nupkg `
    -UbuntuFeedDirectory /tmp/ubuntu-source-feed -OutputDirectory /tmp/source-library-consumer
```

The consumer compiles without network access using only the two supplied packages
and archive inputs. It compares restored ZIP and loaded-output DLL hashes with
the supplied packages, then runs against a disposable real MariaDB server on an
internal Docker network. No database port is published. Random test credentials
are not included in evidence; owned containers and network are removed in a
finally block.

Assertions cover parameterized insertion, typed Unicode/decimal mapping,
transaction rollback and the original public assembly identities, including
MySqlConnector's signing token. A separate MariaDB CLI query checks the committed
row's literal UTF-8 bytes/value and absence of the rolled-back row. Logs, source
package hashes, image identities and result metadata stay in the output directory.

This verifies selected framework-dependent library behavior on linux/arm64. Report
native versus emulated execution according to the Docker engine. It does not
establish upstream suite coverage, all authentication/TLS/plugin paths, other
TFMs/architectures, trimming, a complete grate migration or an installed .deb.

## Remaining archive work

The rebuilt packages are experiments from declared sources, not existing Ubuntu
Build-Depends. Packaging/sponsorship of the dependency chain, complete copyright
and notices, reproducibility and security ownership still need review. Preserve
the original source license texts even when a NuGet package only declares SPDX
metadata. The prior upstream-NuGet inventory describes a different graph: export
the adapted consumer's actual assets when evaluating these rebuilt packages.

The [source-package PoC](../README.md) accepts the two rebuilt packages as explicit
inputs, with hash/revision records and an opt-in archive-analyzer quilt patch.
The original upstream analyzer baseline remains the default. Its
[installed-artifact tests](../tests/README.md) are separate from this library
consumer. Archive-ready dependency packaging and a self-sufficient source build
chain still require further work.
