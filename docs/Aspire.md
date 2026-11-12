---
title: Aspire migrations and ACA init containers
nav_order: 9
---

# Aspire migrations and ACA init containers

The unpublished Aspire integration targets `net10.0` and Aspire 13.6.5, with
`gratedevs/grate:2.3.0` as its default migration image. The
[runnable examples](https://github.com/grate-devs/grate/blob/main/examples/aspire/README.md)
cover PostgreSQL, SQL Server, SQLite, Oracle, MySQL and MariaDB. An optional Azure
module packages SQL into an image and runs it as an Azure Container Apps init
container before the application's main containers start.

| Package in this checkout | Integration |
| --- | --- |
| `grate.aspire.hosting` | Typed PostgreSQL, SQL Server and SQLite resources; explicit-provider connection resources; SQL image packaging |
| `grate.aspire.oracle` | Native `Aspire.Hosting.Oracle` database resources |
| `grate.aspire.mysql` | Native `Aspire.Hosting.MySql` database resources, including a MariaDB server using the compatible resource |
| `grate.aspire.azure` | Azure Container Apps init-container publishing |

The optional database adapters use the same `Grate.Aspire.Hosting` namespace.
SQLite uses `CommunityToolkit.Aspire.Hosting.Sqlite` 13.6.1; the other hosting
packages use 13.6.5. These projects are separate from grate's migration engine
and its target frameworks. None of the Aspire packages has been published.

## Use the extension

Given an Aspire PostgreSQL database resource and an existing script directory:

```csharp
using Grate.Aspire.Hosting;

var migration = database
    .AddGrateMigration()
    .WithScriptsFolder(scripts);

builder.AddProject<Projects.Api>("api")
    .WithReference(database)
    .WaitForCompletion(migration);
```

The typed overloads derive their deferred connection, provider and readiness
dependency. They name the resource `<database-resource-name>-grate`, set
`CREATE_DATABASE=false`, and default grate's environment to `LOCAL`. Consumers
choose their completion dependencies explicitly.

| Database | Resource and creation ownership |
| --- | --- |
| PostgreSQL | `AddPostgres(...).AddDatabase(...)`; native Aspire provisions the database |
| SQL Server | `AddSqlServer(...).AddDatabase(...)`; native Aspire provisions the database |
| MySQL / MariaDB | Native MySQL database resource; Aspire provisions the database. Both use grate's `mariadb` provider |
| Oracle | `AddOracle(...).AddDatabase("appdb", "FREEPDB1")` selects an existing service/PDB using SYSTEM credentials; it does not create a PDB or application user |
| SQLite | A dedicated shared file directory, described below |

The [Oracle](https://github.com/grate-devs/grate/blob/main/examples/aspire/Oracle/README.md),
[MySQL](https://github.com/grate-devs/grate/blob/main/examples/aspire/MySql/README.md)
and [MariaDB](https://github.com/grate-devs/grate/blob/main/examples/aspire/MariaDb/README.md)
examples describe their image settings and local administrator credentials.

For an already provisioned database or another resource implementing
`IResourceWithConnectionString`, select the provider explicitly:

```csharp
var database = builder.AddConnectionString("appdb");
var migration = database.AddGrateMigration(
        GrateDatabaseProvider.PostgreSql, waitForDatabase: false)
    .WithScriptsFolder("../db");
```

Supply `ConnectionStrings:appdb` through secret configuration. The helper never
infers a provider by parsing connection-string text and does not provision an
external database. Arrange its connectivity and readiness yourself.

## SQLite has a file boundary

```csharp
var database = builder.AddSqlite("appdb",
    databasePath: Path.GetFullPath("../data", builder.AppHostDirectory),
    databaseFileName: "app.db");
var migration = database.AddGrateMigration()
    .WithScriptsFolder(scripts);
```

There is no database server or server-readiness wait. The helper mounts the
dedicated database directory read-write at `/grate-data`, including SQLite's
journal/WAL files, and maps the migration connection to that container path.
The database resource's connection stays unchanged for the host API. A consumer
running in another container must explicitly share the storage and use its own
container path; referencing the host connection alone is insufficient.

Use an absolute path in a dedicated directory. In-memory databases, URI sources,
shared temporary/root directories and paths that cannot preserve the toolkit's
host connection semantics are rejected, including semicolons or surrounding
whitespace. The scripts mount cannot overlap the data mount. The SQLite overload
also accepts `containerDataPath` to change the container's data directory.

On Unix hosts, the SQLite migration uses the AppHost's effective UID/GID so the
application can write files created by the container. Its bundle extraction and
output default to writable container-local `/tmp/grate-bundle` and
`/tmp/grate-output`. Script read-only mounting does not make the data directory
read-only. This ownership mapping does not by itself define remote filesystem or
multi-replica SQLite support.

## Script selection and completion

`WithScriptsFolder` resolves paths against the AppHost directory, requires an
existing directory, and mounts it read-only at `/db`. Calling it again replaces
its previous script mount while preserving unrelated mounts. Omitting it prevents
the migration from starting. SQL validity is checked by grate during execution.

The consumer explicitly waits for exit code zero. Migration failure blocks its
initial startup; rerunning a migration does not stop an already running API.

## Overrides

The returned builder supports normal Aspire container customization:

```csharp
var migration = database.AddGrateMigration("catalog-migrate")
    .WithScriptsFolder("../sql", containerPath: "/migration scripts")
    .WithImage("gratedevs/grate", "2.3.0")
    .WithEnvironment("ENVIRONMENT", "TEST")
    .WithEnvironment("TRANSACTION", "true")
    .WithEnvironment("VERSION", "2026.11")
    .WithArgs("--commandtimeout=120");
```

Use Aspire's registry/tag/digest methods for image selection and
`WithContainerName` for an explicit runtime name. The default image version is
pinned; the library does not resolve `latest` automatically.

`WithEnvironment` also overrides `APP_CONNSTRING`, `DATABASE_TYPE`,
`CREATE_DATABASE` and `GRATE_OUTPUT_PATH` (`/output` for servers, `/tmp/grate-output`
for SQLite). Keep connections as
deferred expressions or secret references for correct container networking.
Use `WithScriptsFolder` to change mount and CLI path together; its third argument
controls read-only mounting. Use `WithArgs` for additional CLI options rather
than repeating the launcher-owned settings. Provider and creation overrides
change the caller's connection/permission contract.

On server resources, `AddGrateMigration(waitForDatabase: false)` opts out of readiness.
The caller must then declare the intended readiness dependency explicitly.
Consumers still choose their own completion waits.

## Boundaries

The package replaces the image's entrypoint with a fixed `/bin/sh` launcher that
executes `/app/grate` with one set of arguments. This keeps custom mount targets
consistent without duplicate CLI options. Override images must provide both paths
and the compatible grate CLI contract. The shell uses `exec` to preserve exit
status and signal delivery, and forwards additional arguments without evaluating
them as shell source.

Runtime credentials become process arguments and can be visible through container
inspection or diagnostics. Review output before sharing it. Keep one migration
owner per database; history does not serialize concurrent AppHosts. Cancellation
does not guarantee rollback of earlier SQL; inspect state/history before retrying.

Database persistence remains caller-owned. Server databases need a retained volume
and stable runtime password; SQLite needs its retained directory. Migration output
is ephemeral unless mounted.

## Azure Container Apps init containers

Reference `grate.aspire.azure`, declare an ACA environment, and configure the
migration before attaching it to the application:

```csharp
using Grate.Aspire.Azure;
using Grate.Aspire.Hosting;

if (builder.ExecutionContext.IsPublishMode)
{
    builder.AddAzureContainerAppEnvironment("aca");
}
var database = builder.AddConnectionString("appdb");
var migration = database.AddGrateMigration(
        GrateDatabaseProvider.PostgreSql, waitForDatabase: false)
    .WithScriptsFolder("../db");

builder.AddProject<Projects.Api>("api")
    .WithReference(database)
    .WithGrateMigrationInitContainer(migration, environment: "PRODUCTION");
```

The helper is called on the application. Locally it adds the successful
`WaitForCompletion` dependency; the shared local migration keeps `LOCAL`.
When publishing, it packages SQL in a derived grate image, adds that image as an
init container in the application's ACA template, and suppresses a separate
migration Container App. Native Aspire builds and pushes the migration image;
the application's actual provisioning step depends on that image push. Select
the application's ACA environment first if the AppHost has more than one.

`environment` is mandatory and selects grate scripts for this init container.
It is separate from the Aspire CLI's deployment environment option. Connection
values remain deferred secret references; literal connection strings and
published connection-parameter defaults are rejected. Configure the SQL folder
and base image before calling the ACA helper.

Publishing snapshots only `.sql` files, preserving their relative paths and
bytes. Non-SQL files, including configuration files, are not packaged. Symbolic
links and additional runtime mounts are rejected. Aspire owns the temporary
build context: use the native publish/deploy pipeline while its AppHost is alive.
A legacy exported manifest that points at that context is not a portable handoff
for an independent build after the AppHost exits.

ACA runs the init container at every replica startup, including restarts and
scale-out. It is not a once-per-deployment migration or a global lock. A failed
init blocks that replica's main containers. Concurrent replicas or applications
can race against the same database; serialize independent migrations or coordinate
the deployment externally. Script history does not provide that serialization,
and everytime scripts can run again. No SQL rollback guarantee is added.

The [ACA example](https://github.com/grate-devs/grate/blob/main/examples/aspire/AzureContainerApps/README.md)
uses an existing PostgreSQL database and includes offline publication checks.
Those checks inspect native Bicep and pipeline dependencies and execute the
packaged SQL locally; they do not deploy to Azure or establish live Azure behavior.

## Other deployment boundaries

`PublishAsGrateMigrationImage()` in the base package can package SQL for another
consumer-owned deployment integration. It does not create a platform startup gate
by itself. Generic manifest output does not turn a local `WaitForCompletion`
annotation into rollout ordering.

| Target | Current integration boundary |
| --- | --- |
| Azure Container Apps | Optional init-container adapter described above |
| Kubernetes | No grate init/Job adapter. The pinned publisher rejects bind mounts; without the mount, a normal container becomes a Deployment, not a finite migration Job |
| Azure App Service | No grate predeployment adapter. Use an explicitly executed and awaited migration job or pipeline step |

The Kubernetes observation uses `13.6.5-preview.1.26559.7`. See the pinned
[Kubernetes](https://github.com/microsoft/aspire/blob/v13.6.5/src/Aspire.Hosting.Kubernetes/KubernetesResource.cs)
and [App Service](https://github.com/microsoft/aspire/blob/v13.6.5/src/Aspire.Hosting.Azure.AppService/AzureAppServiceEnvironmentResource.cs)
publishers for their underlying resource behavior.

SQLite publishing is explicitly rejected: the local shared-file helper does not
define durable cloud storage, shared paths or filesystem locking for replicas.
See [SQLite's network-use guidance](https://www.sqlite.org/useovernet.html).

## Build and verification

[`grate.aspire.slnx`](https://github.com/grate-devs/grate/blob/main/grate.aspire.slnx) isolates the prototype from the core
provider matrix and release-package inventory. Build it, run the model tests,
then execute the examples' smoke checks sequentially. See their README files for
commands and cleanup.
[`Verify-AspirePackage.ps1`](https://github.com/grate-devs/grate/blob/main/scripts/Verify-AspirePackage.ps1) also restores and
executes a separate consumer of the four locally packed packages.
[`Verify-AspirePublication.ps1`](https://github.com/grate-devs/grate/blob/main/scripts/Verify-AspirePublication.ps1)
runs the offline ACA artifact and packaged-image checks. The dedicated Aspire
workflow covers the resource models, all six database examples, isolated package
consumption and offline publication without publishing packages or calling Azure.
It bootstraps the native CLI/bundle before building. The reusable
[`Install-AspireCli.ps1`](https://github.com/grate-devs/grate/blob/main/scripts/Install-AspireCli.ps1)
pins 13.6.5 and verifies the release archive's SHA512 checksum. It accepts
`linux-x64` or `osx-arm64` and a new destination directory, then returns `CliPath`
and `BundlePath` for the `AspireCliPath`/`AspireCliBundlePath` build settings.

The repository's SDK selection stays unchanged. The documented stable .NET 10
fallback can check the net10-only adapter from outside the checkout; it does not
establish compatibility with other frameworks. See the
[integration assessment](design/aspire-integration.md) for design and scope.
