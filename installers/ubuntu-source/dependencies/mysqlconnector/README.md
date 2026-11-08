# Source-building MySqlConnector for the Ubuntu experiment

This bounded experiment rebuilds MySqlConnector 2.6.2 from upstream commit
`775689bb3e1ab55d16171e0795264fa746e364c4`. It uses the Ubuntu 26.04 archive SDK
and source-built-artifact feed described in [the parent recipe](../../README.md).
Source acquisition and builder provisioning use networking; restore, compilation
and packing run in a fresh native arm64 Docker container with `--network=none`.
No developer cache or upstream MySqlConnector binary package is an input.

Acquire the exact source separately:

```powershell
git clone --filter=blob:none --no-checkout https://github.com/mysql-net/MySqlConnector.git /tmp/mysqlconnector-source
if ($LASTEXITCODE -ne 0) { throw 'Source acquisition failed.' }
git -C /tmp/mysqlconnector-source checkout --detach 775689bb3e1ab55d16171e0795264fa746e364c4
if ($LASTEXITCODE -ne 0) { throw 'Exact source checkout failed.' }
```

Prepare an empty local feed directory, then extract only the distribution's
source-built artifact tarball into it. This uses the already provisioned builder:

```powershell
$feed = '/tmp/mysqlconnector-ubuntu-feed'
New-Item -ItemType Directory -Path $feed | Out-Null
docker run --rm --pull=never --network=none --platform=linux/arm64 `
    --mount "type=bind,src=$feed,dst=/feed" `
    grate-ubuntu-source:26.04 sh -c `
    'tar -xzf /usr/lib/dotnet/source-built-artifacts/Private.SourceBuilt.Artifacts.10.*.tar.gz -C /feed'
if ($LASTEXITCODE -ne 0) { throw 'Archive feed extraction failed.' }
```

Run both modes with separate new output directories:

```powershell
pwsh -NoProfile -File installers/ubuntu-source/dependencies/mysqlconnector/Invoke-SourceBuild.ps1 `
    -SourceDirectory /tmp/mysqlconnector-source `
    -UbuntuFeedDirectory /tmp/mysqlconnector-ubuntu-feed `
    -OutputDirectory /tmp/mysqlconnector-canonical -Mode Canonical

pwsh -NoProfile -File installers/ubuntu-source/dependencies/mysqlconnector/Invoke-SourceBuild.ps1 `
    -SourceDirectory /tmp/mysqlconnector-source `
    -UbuntuFeedDirectory /tmp/mysqlconnector-ubuntu-feed `
    -OutputDirectory /tmp/mysqlconnector-ubuntu-net10 -Mode UbuntuNet10
```

`Canonical` restores and packs the original project and all its target frameworks.
It preserves the upstream global MinVer/StyleCop references and package validation
baseline. Only the restore source configuration and network-based advisory query
change to permit an offline attempt. Missing release tooling, older framework
reference packs or dependency versions are genuine blockers for that attempt;
retain its nonzero exit and log rather than replacing them with a success claim.

`UbuntuNet10` applies these explicit packaging adjustments to a clean exported
copy of that exact commit:

- Remove the global MinVer and StyleCop package references, unavailable from the
  initial archive feed. Set package version 2.6.2, assembly version 2.0.0.0 and
  file version 2.6.2.0 explicitly, preserving the assembly identity expected by
  consumers. Set the exact repository commit in NuGet metadata.
- Build and pack only the upstream `net10.0` target. Disable package validation
  against the upstream 2.5.0 binary baseline, which is not an archive input.
- Select archive `Microsoft.Extensions.Logging.Abstractions` and
  `Microsoft.Extensions.DependencyInjection.Abstractions` 10.0.14 instead of 8.0.2,
  and `System.Diagnostics.DiagnosticSource` 10.0.14 instead of 8.0.1. This is an
  explicit dependency-baseline change, not an assertion of complete release
  equivalence. Central transitive pinning can add archive dependencies to the
  resulting nuspec; inspect the actual package.

The runtime source and original `MySqlConnector.csproj` remain unchanged, retaining
public signing with the upstream key, friend-assembly declarations, generated
regular expressions, documentation and AOT/trimming annotations. The recipe does
not replace the original project with a source-file glob or weaken its warning
policy. AOT annotations do not establish successful AOT execution.

Each mode uses `git archive` to exclude developer build/cache state. Output must
not exist beforehand. The archive feed is mounted read-only; every invocation
uses fresh package, HTTP, plugin and CLI caches. Output includes exact Docker
arguments, builder inspection, complete installed package versions, source tarball
hash, adjusted central props, raw logs and result metadata. The package, if built,
appears under `packages/MySqlConnector.2.6.2.nupkg`. Keep logs and measurements
outside git and retain them with the actual package hash.

The local package intentionally keeps the version/assembly identity needed by the
Grate PoC, while containing only net10.0 assets and a different dependency baseline.
Use it in an isolated experiment feed and record its hash and provenance. It does
not replace the upstream release across supported frameworks or establish Ubuntu
archive acceptance. Upstream test suites, authentication modes, encryption or
compression plugins, all server versions, other architectures and AOT execution
need their own verification. A real MariaDB consumer and the Grate migration/rerun
checks provide separate runtime evidence after this source build.

The upstream source contains its MIT license and copyright. The packed upstream
project declares MIT through NuGet metadata; the final Grate binary package still
needs the complete actual license/copyright texts through the compliance audit.
Successful local restore/pack is not that notice audit or an archive upload.
