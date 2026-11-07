# Linux x64 SQLite distribution PoC

Build two variants of the same CLI project, `All` and `SQLite`, using
`GrateDistribution`. The default remains `All`. The SQLite variant uses the
`grate-sqlite` NuGet tool ID and installed command. Both standalone archives
contain an executable named `grate`.

## Run the comparison

From the repository root on Linux x64, with Python 3 and the SDK pinned in
`global.json`, run the script with a fresh output directory.

```sh
python3 docs/design/sqlite-only-poc/verify.py --output "$PWD/artifacts/sqlite-poc"
```

Docker can supply Linux x64 and the pinned SDK on another host. On Apple
Silicon this uses x64 emulation. The following command installs Python into
the disposable container and runs the same comparison.

```sh
docker run --rm --platform linux/amd64 \
  -v "$PWD:/src" -w /src \
  mcr.microsoft.com/dotnet/sdk:11.0.100-rc.3@sha256:59d092a889fbad09c1a0b0c5dd072c6315125b0294a5cddfa48ec892f63b2ab3 \
  sh -c 'apt-get update -qq && apt-get install -y -qq python3 &&
    python3 docs/design/sqlite-only-poc/verify.py --output /src/artifacts/sqlite-poc'
```

Each variant gets separate standalone and tool build roots. The script publishes
a self-contained `net11.0` Linux x64 binary with the project's existing trimming
and single-file settings. It packs a framework-dependent tool with the project's
`net8.0`, `net9.0`, `net10.0` and `net11.0` assets, then installs the exact
version from a local-only NuGet feed with an isolated cache, installs into its
own tool directory and checks that the installed package bytes match the build. Tool execution
uses `net11.0`.

## What it checks

- Run each extracted standalone executable and installed tool against its own
  SQLite file. Create a table and seed a row, rerun, and independently query the
  SQLite data, script hashes and history to check that the one-time script ran
  once. Check that the migration error table is empty.
- Exercise the SQLite default and explicit SQLite selection. Check that another
  provider is rejected before a database file is created, and that help identifies
  SQLite. Install the bundled skill through each packaged executable.
- Inspect standalone dependency metadata and every framework's tool dependency
  metadata. Require SQLite and exclude the four other provider assemblies and
  their client libraries from the SQLite build.
- Measure both variants' raw executable, ZIP and tool package bytes with matched
  versions and build settings. ZIPs use the same Python deflate compression level.

`results.json` contains the measurements and savings. Each variant directory
contains its ZIP, NuGet package, build logs, installed tool, SQLite files and
migration logs. Keep these point-in-time outputs in local artifacts or the PR
verification record. The design proposal describes the larger release discussion.
[SQLite distribution proposal](../sqlite-only-distributions.md)
