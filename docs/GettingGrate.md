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

There's a `{{ site.github.repository_nwo }}` docker image published to [dockerhub](https://hub.docker.com/r/{{ site.github.repository_nwo }}) on every release.  See the [examples](https://github.com/grate-devs/grate/tree/main/examples) folder for a demo using this to a migration.

The Docker image is built on Alpine Linux, making it lightweight and suitable for containerized environments. For more information about Alpine Linux support, see [Alpine Linux Support](AlpineLinuxSupport.md).

Start the sqlserver database 
```sh
docker network create grate_network && docker run -e SA_PASSWORD=gs8j4AS7h87jHg -e ACCEPT_EULA=Y --name db --network grate_network -d mcr.microsoft.com/mssql/server:2019-latest
```
Run grate migration
```sh
docker run -v ./examples/docker/db:/db  -e APP_CONNSTRING="Server=db;Database=grate_test_db;User Id=sa;Password=gs8j4AS7h87jHg;TrustServerCertificate=True" --network grate_network grate-devs/grate
# run with database type, accept: sqlserver, postgresql, mariadb, sqlite, oracle
# docker run -v ./examples/docker/db:/db -e DATABASE_TYPE=sqlserver -e CREATE_DATABASE=true -e ENVIRONMENT=Dev -e TRANSACTION=true -e APP_CONNSTRING="Server=db;Database=grate_test_db;User Id=sa;Password=gs8j4AS7h87jHg;TrustServerCertificate=True" --network grate_network grate-devs/grate  
```

Cleanup resources
```sh

docker kill db  || docker network rm grate_network  || docker rm $(docker ps -f status=exited | awk '{print $1}')  
```

## Dotnet Tool

grate is available as a [dotnet global tool](https://docs.microsoft.com/en-us/dotnet/core/tools/global-tools).  Simply `dotnet tool install -g grate` to get the [package](https://www.nuget.org/packages/grate/).

The tool and library packages target .NET 8, 9, 10 and 11. Install a matching
.NET runtime; installing a local or global tool also requires the .NET SDK.
For .NET 11, install the [RC3 SDK](https://dotnet.microsoft.com/download/dotnet/11.0)
(`11.0.100-rc.3.26522.148`) or a newer supported .NET 11 release. An RC3-only
machine can install and run the tool's `net11.0` assets; no older runtime is needed.
Use `--version <grate-version>` to select a particular grate release. Only use
`--prerelease` if the **grate package version** is itself a prerelease.

## NuGet libraries

Applications can reference `grate.core` and the provider packages
`grate.sqlserver`, `grate.postgresql`, `grate.mariadb`, `grate.oracle` and
`grate.sqlite`. Each package includes assets for .NET 8, 9, 10 and 11.

## Runtime and platform requirements

New self-contained CLI archives, MSI and Debian packages, Chocolatey packages,
and Docker images bundle .NET runtime `11.0.0-rc.3.26522.148`. Homebrew and
winget install those same release binaries or installers. These distributions
need no separately installed .NET runtime; native OS dependencies still apply.
The Docker images use Alpine 3.24 and include the .NET native dependencies and ICU
for globalization.

.NET 11 RC3 has a go-live license and is supported by Microsoft in production
until November 10, 2026 ([support policy](https://dotnet.microsoft.com/platform/support/policy/dotnet-core)).
This allows grate releases before .NET 11 GA. When GA is available, the bundled
runtime must be updated by rebuilding and reinstalling these distributions;
installing a newer runtime on the host does not update self-contained grate.

The existing Windows (x86/x64/Arm64), Linux (x64/Arm64, glibc or musl) and macOS
(x64/Arm64) binaries remain available. Check Microsoft's
[supported OS list](https://github.com/dotnet/core/blob/main/release-notes/11.0/supported-os.md)
and [.NET 11 hardware requirements](https://learn.microsoft.com/dotnet/core/compatibility/jit/11/minimum-hardware-requirements).
In particular, x86/x64 binaries now require the `x86-64-v2` instruction baseline;
the minimum Arm64 hardware requirements are unchanged.

## Winget

grate is available on [winget](https://docs.microsoft.com/en-us/windows/package-manager/winget/).  Simply `winget install erikbra.grate` for awesome!

## Homebrew

grate is available as a Homebrew cask. Simply `brew install --cask erikbra/cask/grate` for awesomeness!

## Agent skill

New grate CLI builds bundle the `use-grate` coding-agent skill in every CLI
distribution. After installing, run `grate skills install --global` for your user,
or `dotnet tool run grate -- skills install --local` for a repository-local .NET
tool. See [Agent skill](AgentSkill.md) for locations, updates, Docker and SDK-free
installation. This is an explicit step; installing grate alone does not change
your agent configuration.

## Notes

Plans are afoot for more OS specific package managers, watch this space.
