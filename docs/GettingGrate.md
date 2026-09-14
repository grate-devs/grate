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

Note, pre-requisite is dotnet 6. If the above command gives you: 

```
error NU1202: Package grate *.*.* is not compatible with net5.0 (.NETCoreApp,Version=v5.0) / any. 
Package grate 0.10.0 supports: net6.0 (.NETCoreApp,Version=v6.0) / any

please install dotnet 6 (download [here](https://dotnet.microsoft.com/download/dotnet/6.0)).

* You are attempting to install a preview release and did not use the --version option to specify the version.
* A package by this name was found, but it was not a .NET tool.
* The required NuGet feed cannot be accessed, perhaps because of an Internet connection problem.
* You mistyped the name of the tool.

For more reasons, including package naming enforcement, visit https://aka.ms/failure-installing-tool
```
please install [dotnet 6](https://dotnet.microsoft.com/download/dotnet/6.0)

## Winget

grate is available on [winget](https://docs.microsoft.com/en-us/windows/package-manager/winget/).  Simply `winget install erikbra.grate` for awesome!

## Homebrew

grate is available as a Homebrew formula:

```sh
brew install grate
```

The formula installs a self-contained binary, so the .NET runtime is not required on the target computer.

## Notes

Plans are afoot for more OS specific package managers, watch this space.
