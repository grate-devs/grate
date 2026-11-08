# CLI performance experiments

This is measurement infrastructure for [#919](https://github.com/grate-devs/grate/issues/919); release defaults remain unchanged and the issue remains open.
Keep point-in-time measurements, traces and decisions in CI artifacts or linked
review records, rather than committing reports to this directory.

## Prerequisites and scope

Use native Linux x64 or Arm64, PowerShell 7, Git, the SDK selected by
`global.json`, GNU `tar`, GNU `time` at `/usr/bin/time`, and the `sqlite3` CLI.
For optional Native AOT investigation, also install `clang` and `zlib1g-dev`.
The workflow installs measurement dependencies and the pinned SDK. Local Ubuntu hosts can install the native dependencies with:

```powershell
sudo apt-get update
sudo apt-get install --yes --no-install-recommends sqlite3 time
# Only for the optional Native AOT experiment:
sudo apt-get install --yes --no-install-recommends clang zlib1g-dev
```

Run from the repository root in PowerShell. Keep the checkout unchanged while
publishing all candidates. Outputs must be outside the checkout and each publish
or measurement invocation requires a new output directory.
Use `-EnvironmentNotes` to record host hardware, VM/container and storage details
that cannot be inferred from inside the measured environment. Publish everything
before measuring and keep competing builds/workloads out of the timed rounds.

## Matching candidates and two measurement rounds

These commands match `cli-performance.yml`; choose the RID matching the native
host. For a native Arm64 container use `linux-arm64` and `container-native`.
The execution-mode value is an operator attestation. The harness also checks the
process architecture against the RID; that check alone cannot detect emulation.

```powershell
./scripts/performance/Test-BenchmarkFixtures.ps1
$rid = 'linux-x64'
$root = Join-Path ([IO.Path]::GetTempPath()) ('cli-performance-' + [Guid]::NewGuid().ToString('N'))
$candidates = @('baseline', 'uncompressed', 'selective-extraction', 'ready-to-run')
foreach ($candidate in $candidates) {
    ./scripts/performance/Publish-CliBenchmark.ps1 -RuntimeIdentifier $rid -Candidate $candidate -OutputDirectory "$root/$candidate"
}
foreach ($round in 1..2) {
    if ($round -eq 2) {
        [array]::Reverse($candidates)
    }
    foreach ($candidate in $candidates) {
        $arguments = @{
            Executable = "$root/$candidate/publish/grate"
            BuildManifest = "$root/$candidate/build.json"
            OutputDirectory = "$root/$candidate/round-$round"
            Iterations = 10
            ExecutionMode = 'native'
        }
        ./scripts/performance/Invoke-CliBenchmark.ps1 @arguments
    }
}
```

Forward and reverse rounds expose order-related drift but do not eliminate shared-runner noise. Repeat on stable hardware and inspect distributions before
selecting numerical improvement targets or publishing settings.

| Candidate | Difference from the matching baseline |
| --- | --- |
| `baseline` | Current self-contained Release settings: partial trimming, compressed single file, all-content extraction, ReadyToRun disabled. |
| `uncompressed` | Sets `EnableCompressionInSingleFile=false`. |
| `selective-extraction` | Sets `IncludeAllContentForSelfExtract=false`; native-library extraction remains enabled. |
| `ready-to-run` | Sets `PublishReadyToRun=true`; composite and Crossgen2 choices retain SDK defaults, whose evaluated values are recorded. This is not a separate composite experiment. |
| `native-aot` | Sets `PublishAot=true`; disables single-file bundling, compression and all-content extraction for that publishing path. This is feasibility investigation. |

All candidates retain the all-in-one provider references, including Oracle, globalization and bundled skill resources. The publisher selects the last target
framework declared by the project. It does not merge the #909/#910 slim PoC or
compare removed providers against compiler improvements. Future slim experiments
need their own matching baseline and profile metadata.

Optional AOT invocation, after the prerequisites above:

```powershell
$aotRoot = "$root/native-aot"
./scripts/performance/Publish-CliBenchmark.ps1 -RuntimeIdentifier $rid -Candidate native-aot -OutputDirectory $aotRoot
./scripts/performance/Invoke-CliBenchmark.ps1 -Executable "$aotRoot/publish/grate" -BuildManifest "$aotRoot/build.json" -OutputDirectory "$aotRoot/measurements" -Iterations 10 -ExecutionMode native
```

Publishing failures stop the experiment and retain available diagnostics. Warnings are made visible for every candidate, including baseline; selected trim/AOT
warning codes are nonfatal during investigation. Visibility, a successful build,
and SQLite checks do not establish trimming/AOT compatibility for every provider,
reflection path, authentication method or platform. Investigate warnings
individually before adopting changes; retain the working self-contained fallback.

## What is measured and independently checked

Each measured operation starts a new CLI process. GNU time provides peak resident
KiB and CPU time; a high-resolution wall timer includes the small time-wrapper
startup overhead. Setup, database copies, assertions and footprint scans are
outside the timed interval. One warmup per workload/condition is excluded from
summaries by default; raw records retain setup, warmups and individual samples.
Migration samples explicitly select console logging so CI autodetection does not
change the measured logger between local and hosted runs.

Workloads are help, the existing `--version` argument-error path, an up-to-date
database, 100 small insert scripts, one script inserting 10,000 rows, and a failing
migration. `--version` sets the migration version and requires a value; it is not
an informational version switch. Its parse-error workload preserves exit code 1.
Help checks representative options/providers. SQLite assertions inspect Unicode
data, ordered history, stored hashes/text, unchanged identities after rerun,
error history, retained preceding effects and absence of subsequent effects.
The packaged engine writes its own SQLite version for independent inspection.

`first-extraction` uses a new bundle directory per process; `reused` uses a prepopulated directory. Neither flushes OS caches. These are not genuinely cold
cache measurements. Migration time includes SQLite execution and file I/O;
help/parser startup offers a separate initialization comparison, not subtraction
of all database overhead. Remote connection/authentication/network latency and
transaction rollback are unmeasured; grate's SQLite provider does not support
DDL transactions. Other providers, authentication/TLS, failure modes, supported
OSes and native dependencies still need matching packaged-artifact checks before
support claims or adoption. Docker-based packaged checks are available separately:

```powershell
./scripts/performance/Test-CliWithoutRuntime.ps1 -Executable "$root/baseline/publish/grate" -BuildManifest "$root/baseline/build.json" -OutputDirectory "$root/baseline/runtime-free"
```

This uses a pinned runtime-deps image, rejects an installed dotnet host/runtime,
and checks SQLite migration/rerun/failure plus bundled skill installation. It does
not time containers or establish other providers' compatibility.

## Evidence and interpretation

`build.json`, `source.patch` and `publish.log` identify source, dirty state,
untracked-file hashes, SDK/runtime patch, profile, RID, configuration, evaluated
settings and executable SHA256. Compare matching inputs and inspect dirty-source
evidence. `metadata.json`, `measurements.jsonl`, `summary.json` and per-process logs
retain hardware/OS/container limits, conditions, samples and variability. Only
fully validated runs set `complete=true`. CI uploads available evidence even on
failure. PRs run fixture/oracle checks and short packaged smoke measurements on
both native RIDs; manual dispatch uses the representative default fixture sizes.
Uploads omit executables, archives and extracted dependency bytes; retain exact
artifact hashes and size measurements while dependency notices are audited.

Sizes include executable bytes, logical installed file bytes, extraction bytes and a normalized gzip tar of the complete publish directory. That archive is a
download surrogate, not the exact release ZIP, installer or allocated disk usage.
No automatic performance threshold or release-setting change is imposed. Review
size, latency, memory and correctness tradeoffs together. Coordinate dependency
notices and any trimming/linking/AOT transformations with the separate NuGet
compliance audit; this harness does not determine legal compliance.
