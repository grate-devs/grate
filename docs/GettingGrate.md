---
title: "Getting Grate"
permalink: /getting-grate/
nav_order: 3
---

# Getting Grate

There's a variety of ways to access grate depending on your needs:

## Source Code/raw binaries

The [github site](https://github.com/grate-devs/grate/) has both the raw source code for local compilation, and also has binaries for a variety of OS's published at [each release](https://github.com/grate-devs/grate/releases/latest).

Binaries are available for Windows, Linux (glibc and musl), and macOS across multiple architectures. The linux-musl binaries are compatible with Alpine Linux.

## Docker

There's a `gratedevs/grate` Docker image published to [Docker Hub](https://hub.docker.com/r/gratedevs/grate) on every release. See the [examples](https://github.com/grate-devs/grate/tree/main/examples) folder for a demo using this for a migration.

`gratedevs/grate` is the canonical Docker image. The compatibility name
`erikbra/grate` remains available during the transition.

The Docker image is built on Alpine Linux, making it lightweight and suitable for containerized environments. For more information about Alpine Linux support, see [Alpine Linux Support](AlpineLinuxSupport.md).

For Azure Container Apps Jobs, see how to [capture console logs on a persistent volume](ConfigurationOptions/index.md#azure-container-apps-jobs).

Start the sqlserver database 
```sh
docker network create grate_network && docker run -e SA_PASSWORD=gs8j4AS7h87jHg -e ACCEPT_EULA=Y --name db --network grate_network -d mcr.microsoft.com/mssql/server:2019-latest
```
Run grate migration
```sh
docker run -v ./examples/docker/db:/db  -e APP_CONNSTRING="Server=db;Database=grate_test_db;User Id=sa;Password=gs8j4AS7h87jHg;TrustServerCertificate=True" --network grate_network gratedevs/grate
# run with database type, accept: sqlserver, postgresql, mariadb, sqlite, oracle
# docker run -v ./examples/docker/db:/db -e DATABASE_TYPE=sqlserver -e CREATE_DATABASE=true -e ENVIRONMENT=Dev -e TRANSACTION=true -e APP_CONNSTRING="Server=db;Database=grate_test_db;User Id=sa;Password=gs8j4AS7h87jHg;TrustServerCertificate=True" --network grate_network gratedevs/grate
```

Cleanup resources
```sh

docker kill db  || docker network rm grate_network  || docker rm $(docker ps -f status=exited | awk '{print $1}')  
```

## Dotnet Tool

grate is available as a [dotnet global tool](https://docs.microsoft.com/en-us/dotnet/core/tools/global-tools).  Simply `dotnet tool install -g grate` to get the [package](https://www.nuget.org/packages/grate/).

The tool and library packages target .NET 8, 9, 10 and 11. Install a matching
.NET runtime; installing a local or global tool also requires the .NET SDK.
For .NET 11, install the [stable SDK](https://dotnet.microsoft.com/download/dotnet/11.0)
(`11.0.100`) or a newer supported .NET 11 release. A machine with only the stable
.NET 11 runtime can run the tool's `net11.0` assets; no older runtime is needed.
Use `--version <grate-version>` to select a particular grate release. Only use
`--prerelease` if the **grate package version** is itself a prerelease.

## NuGet libraries

Applications can reference `grate.core` and the provider packages
`grate.sqlserver`, `grate.postgresql`, `grate.mariadb`, `grate.oracle` and
`grate.sqlite`. Each package includes assets for .NET 8, 9, 10 and 11.

Microsoft's support for both .NET 8 and .NET 9 ends on November 10, 2026
([.NET support policy](https://dotnet.microsoft.com/platform/support/policy/dotnet-core)).
We expect to retire grate's .NET 8 and 9 targets in a future release after that
support date; the specific grate release has not been decided. Plan to upgrade
to a supported runtime. The current packages retain both targets.

## Runtime and platform requirements

Self-contained CLI archives, MSI and Debian packages and Chocolatey packages
built from this checkout bundle stable .NET runtime `11.0.0`, including standalone
Linux/musl binaries. Docker images temporarily retain .NET runtime
`11.0.0-rc.3.26522.148` until the stable Alpine 3.24 base images are available.
These distributions need no separately installed .NET runtime; native OS dependencies still apply.
The Docker images use Alpine 3.24 and include the .NET native dependencies and ICU
for globalization.

Homebrew casks and winget packages use the runtime bundled in the release version
they install. A package-manager channel can lag behind the latest grate release;
the existing personal Homebrew tap is still at 1.8.0, as described below.

The proposed [Homebrew/core formula](#homebrew) instead builds from source and
uses Homebrew's shared .NET installation. Homebrew installs that dependency automatically.

Older grate distributions and the temporary Docker exception can still bundle a
prerelease runtime. Move to a distribution rebuilt with stable .NET 11;
installing a newer runtime on the host
does not update self-contained grate. Future runtime servicing likewise requires
rebuilding and reinstalling these distributions.

The existing Windows (x86/x64/Arm64), Linux (x64/Arm64, glibc or musl) and macOS
(x64/Arm64) binaries remain available. Check Microsoft's
[supported OS list](https://github.com/dotnet/core/blob/main/release-notes/11.0/supported-os.md)
and [.NET 11 hardware requirements](https://learn.microsoft.com/dotnet/core/compatibility/jit/11/minimum-hardware-requirements).
In particular, x86/x64 binaries now require the `x86-64-v2` instruction baseline;
the minimum Arm64 hardware requirements are unchanged.

## Winget

grate is available on [winget](https://docs.microsoft.com/en-us/windows/package-manager/winget/).  Simply `winget install erikbra.grate` for awesome!

## Homebrew

The existing Homebrew cask is installed from the personal tap:

```sh
brew install --cask erikbra/cask/grate
```

That legacy tap currently declares grate 1.8.0; this command does not yet install
2.2.0. Use the [release binaries](https://github.com/grate-devs/grate/releases/latest)
or the [.NET tool](#dotnet-tool) for newer published releases while the Homebrew
channels are being updated.

A source-built formula is being prepared for `homebrew/core` alongside grate 2.2.0.
It is not available in core yet. Once the formula has been accepted, the command will be:

```sh
brew install grate
```

The formula will automatically install the required .NET dependency. You will not
need to install or configure .NET separately. The existing cask uses the self-contained
release binary instead. See [Building and releasing packages](Packaging.md#homebrewcore-formula)
for the formula submission steps after the release.

## Agent skill

New grate CLI builds bundle the `use-grate` coding-agent skill in every CLI
distribution. After installing, run `grate skills install --global` for your user,
or `dotnet tool run grate -- skills install --local` for a repository-local .NET
tool. See [Agent skill](AgentSkill.md) for locations, updates, Docker and SDK-free
installation. This is an explicit step; installing grate alone does not change
your agent configuration.

## Notes

Plans are afoot for more OS specific package managers, watch this space.
