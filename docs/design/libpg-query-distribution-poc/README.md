# libpg_query native distribution experiment

This isolated POC builds libpg_query, packages its RID-specific native libraries
with a small managed wrapper, then consumes the resulting local NuGet package
from a fresh .NET application. It lives outside the grate solution and packages.

The upstream input is libpg_query 18.1.0 at commit
`c1546e7e97edc93fe8474d7a59881e91fbf48cfc`. Native build scripts verify that identity.
Builds and package feeds belong in external temporary directories.

## Build one native asset

On macOS or Linux, run from the repository root with a new source directory and
the RID matching the host's architecture and C runtime.

```sh
poc="$PWD/docs/design/libpg-query-distribution-poc"
native=/tmp/grate-libpg-source
assets=/tmp/grate-libpg-assets
feed=/tmp/grate-libpg-feed
git clone --depth 1 --branch 18.1.0 https://github.com/pganalyze/libpg_query.git "$native"
bash "$poc/native/build-unix.sh" "$native" osx-arm64 "$assets"
```

The Unix script also accepts `osx-x64`, `linux-x64`, `linux-arm64`,
`linux-musl-x64` and `linux-musl-arm64`. Linux builds require a host with the
matching architecture and libc. The macOS script targets macOS 11 or newer.

On Windows, use PowerShell 7 with Visual Studio C++ Build Tools installed.
The Windows script selects an amd64-hosted MSVC toolchain for `win-x64`,
`win-x86` or `win-arm64`, builds the upstream static archive with `/MT`, and
links a DLL exporting the two C functions used by the wrapper.

```powershell
& ./docs/design/libpg-query-distribution-poc/native/build-windows.ps1 `
  -SourceDirectory C:/temp/grate-libpg-source `
  -Rid win-x64 -OutputDirectory C:/temp/grate-libpg-assets
```

Both build scripts stage libraries under `runtimes/<rid>/native` and copy
third-party notices under `licenses`. Windows uses `pg_query.dll`, macOS uses
`libpg_query.dylib`, and Linux uses `libpg_query.so`.

## Pack and verify a local consumer

Use a stable .NET 10 SDK from outside the checkout so SDK selection is explicit.
The staging root can contain one RID for a local check or all nine RIDs for the
universal package. Repeated native builds can share that staging root.

```sh
(cd /tmp && dotnet pack "$poc/managed/Interop/LibPgQuery.Interop.csproj" \
  -c Release -p:NativeAssetsRoot="$assets" -o "$feed")
python3 "$poc/verify-package.py" --feed "$feed" --rid osx-arm64 --framework net10.0
```

The local package ID is `Grate.Poc.LibPgQuery.Native` with version `18.1.0-poc.1`.
The managed assembly targets .NET 10 and can also be consumed by the .NET 11
probe. Use `--framework net11.0` with the repository's pinned SDK/runtime.
Add `--complete` to require exactly the nine supported RID assets in the package.

The verifier restores the actual package into a fresh NuGet cache, publishes and
runs a framework-dependent application, then publishes and runs a self-contained
compressed single-file application. The single-file form bundles native assets for
extraction and enables trimming on the platforms where grate does. It checks
the process architecture and compares the selected native bytes with the package
by SHA256. It also checks redistributed notices beside the normal application
and in the bundle extraction directory. A negative control withholds the selected
native library and requires a DllNotFoundException before restoring it.

The .NET smoke code exercises Cdecl calls returning the native parse-result
structure by value. It checks UTF-8 text, JSON parse-tree content, error text and
error position, repeated calls, and release of every returned result through the
native free function.

## Platform matrix

The [isolated workflow](../../../.github/workflows/libpg-query-distribution-poc.yml)
builds all native assets, packs one universal dependency, and gives that same
package to the consumer jobs. The consumers use .NET 11 RC3 and verify both
published application forms.

| RID | Native build environment | Consumer environment |
| --- | --- | --- |
| linux-x64 | Ubuntu 22.04, glibc 2.35 | Ubuntu 22.04 x64 |
| linux-arm64 | Ubuntu 22.04 ARM64, glibc 2.35 | Ubuntu 22.04 ARM64 |
| linux-musl-x64 | Alpine 3.24 x64 | Alpine 3.24 x64 |
| linux-musl-arm64 | Alpine 3.24 ARM64 | Alpine 3.24 ARM64 |
| osx-x64 | macOS 15 Intel | macOS 15 Intel |
| osx-arm64 | macOS 15 ARM64 | macOS 15 ARM64 |
| win-x64 | Windows Server 2025, x64 MSVC | Windows Server 2025 x64 |
| win-x86 | Windows Server 2025, x86 MSVC | Windows Server 2025, x86 process under WoW64 |
| win-arm64 | Windows Server 2025, x64-to-ARM64 MSVC | Windows 11 ARM64 |

The Alpine jobs use the same pinned .NET 11 RC3 SDK image on Alpine 3.24 as the
grate build. The workflow records its image digest. Windows ARM64 loading is
tested on an ARM64 runner after cross-compilation on the x64 build host.

## Evidence boundaries

Native build success, binary-header inspection and successful .NET execution
establish different claims. A matrix entry is verified only when its consumer
actually loads the packaged library and passes the parsing assertions in the
reported runtime environment. Cross-publishing alone does not verify execution.
Workflow logs and artifacts carry individual run results.

This POC covers a short-lived, single-threaded application and the two native
functions it calls. Long-lived memory behavior, thread creation/destruction,
native failure isolation and other C API entry points need separate integration
work. The results apply to the tested OS/libc/runtime versions. Compatibility
with older hosts, code signing, native AOT and installation as a .NET tool remain
separate distribution questions.

The managed wrapper is MIT-licensed. Bundled code retains its own notices for
libpg_query, PostgreSQL, upb, utf8_range and xxHash. The package carries these
notices and makes them available to the published consumers. Package creation
and workflow artifact upload are local/CI experiments. Public package publishing
and adoption by grate require a later decision.
