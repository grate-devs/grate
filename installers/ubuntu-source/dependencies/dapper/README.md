# Dapper source-build experiment

This recipe exports commit `eb47546a408bbf6c178bda4f04dc205bc51ffbfe`, recorded
in Dapper 2.1.89's NuGet metadata. It tests the original library project using
Ubuntu's archive SDK 10.0.114 and source-built inputs, with network access disabled
and fresh caches. Acquire sources separately and follow the
[shared procedure](../README.md).

```powershell
git clone --filter=blob:none --no-checkout https://github.com/DapperLib/Dapper.git /tmp/dapper-source
if ($LASTEXITCODE -ne 0) { throw 'Source acquisition failed.' }
git -C /tmp/dapper-source checkout --detach eb47546a408bbf6c178bda4f04dc205bc51ffbfe
if ($LASTEXITCODE -ne 0) { throw 'Exact source checkout failed.' }

pwsh -NoProfile -File installers/ubuntu-source/dependencies/dapper/Build-FromSource.ps1 `
    -SourceDirectory /tmp/dapper-source -UbuntuFeedDirectory /tmp/ubuntu-source-feed `
    -OutputDirectory /tmp/dapper-upstream -Mode Upstream
pwsh -NoProfile -File installers/ubuntu-source/dependencies/dapper/Build-FromSource.ps1 `
    -SourceDirectory /tmp/dapper-source -UbuntuFeedDirectory /tmp/ubuntu-source-feed `
    -OutputDirectory /tmp/dapper-archive -Mode Archive
```

Both modes select the upstream net10.0 target. `Upstream` preserves the build
references and records missing/incompatible release-tool packages. `Archive`
changes only the exported packaging XML:

- Remove unconditional .NET Framework reference assemblies, Nerdbank versioning,
  SourceLink, ReferenceTrimmer and PublicApiAnalyzers references. These are build
  tooling, not Dapper's net10 runtime dependencies. Their checks are not claimed
  to have run. The compiler and original warnings-as-errors policy remain.
- Supply version 2.1.89, assembly version 2.0.0.0, file version 2.1.89.0 and the
  repository commit explicitly. This preserves the public unsigned assembly
  identity, not every informational/versioning detail of an upstream release.
- Include the original Apache license text in the resulting nupkg. Complete
  copyright/notice handling in the final application package is a separate step.

The script retains the original library project, source files, compiler settings
and embedded-documentation behavior. It records the source archive hash, original
and modified packaging files, patch, image identity, package source configuration
and exact Docker arguments. Result metadata and logs remain outside git.

The output `packages-built/Dapper.2.1.89.nupkg` is a net10-only experiment package;
keep it in an isolated feed with its hash and source provenance. It is not a
replacement for the multi-target upstream release or an approved Ubuntu package.
Use the [real MariaDB consumer](../README.md#verify-the-two-local-packages) to
exercise the locally built Dapper and MySqlConnector assemblies together.
