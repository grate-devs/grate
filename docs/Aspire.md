---
title: Aspire migration prototype
nav_order: 9
---

# Aspire migration prototype

The experimental `grate.aspire.hosting` library targets `net10.0` and Aspire
hosting 13.6.5, with `gratedevs/grate:2.3.0` as its default image. It is not
published; the [runnable example](https://github.com/grate-devs/grate/blob/main/examples/aspire/README.md) references the
local project and includes PostgreSQL, SQL Server and SQLite examples, a minimal
API, SQL fixtures and opt-in Docker smoke checks. SQLite uses
`CommunityToolkit.Aspire.Hosting.Sqlite` 13.6.1; other hosting packages use 13.6.5.

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

The server overloads accept `PostgresDatabaseResource` or
`SqlServerDatabaseResource` builders and derive their deferred connection,
provider and readiness dependency. They name the resource
`<database-resource-name>-grate`, sets `CREATE_DATABASE=false` because Aspire
creates the database, and defaults grate's environment to `LOCAL`.
Aspire 13.6.5 provisions both server database types before the migration starts.
For SQL Server, declare the database with
`builder.AddSqlServer("sqlserver").AddDatabase("appdb")` and use the same migration
extension shown above.

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

## Deployment providers

The normal container resource can be customized with target-specific Aspire APIs,
but the current helper is not deployment-ready unchanged. The generic manifest
does not export `WaitForCompletion` as a rollout gate, and a host script directory
is not a portable migration artifact.

For Aspire 13.6.5 (Kubernetes package `13.6.5-preview.1.26559.7`):

| Target | Current publisher boundary |
| --- | --- |
| Kubernetes | Rejects bind mounts. Without the mount, a normal container becomes a Deployment, not a finite migration Job. |
| Azure Container Apps | Defaults to a continuously running app. `PublishAsAzureContainerAppJob()` models a manual job, but does not itself execute and await it before consumers deploy. Script mounts become Azure Files shares without uploading the local SQL. |
| Azure App Service | The pinned publisher omits this plain image-only migration resource; it is not a predeployment job for the web app. |

See the pinned implementations for
[Kubernetes](https://github.com/microsoft/aspire/blob/v13.6.5/src/Aspire.Hosting.Kubernetes/KubernetesResource.cs),
[Container Apps jobs](https://github.com/microsoft/aspire/blob/v13.6.5/src/Aspire.Hosting.Azure.AppContainers/ContainerAppExtensions.cs),
[Container Apps storage](https://github.com/microsoft/aspire/blob/v13.6.5/src/Aspire.Hosting.Azure.AppContainers/AzureContainerAppExtensions.cs),
and [App Service](https://github.com/microsoft/aspire/blob/v13.6.5/src/Aspire.Hosting.Azure.AppService/AzureAppServiceEnvironmentResource.cs).

A deployment integration needs versioned SQL delivery (for example in the image),
a finite job configured for the target, and explicit execution/success checks
before application rollout. App Service can use a separate job or delivery-pipeline
step. Keep one migration owner per database and define interruption/retry recovery.

SQLite additionally requires durable storage and correct paths for both job and
application. A workstation bind mount does not establish that contract. Validate
filesystem locking before using a remote share; see
[SQLite's network-use guidance](https://www.sqlite.org/useovernet.html).

## Build and verification

[`grate.aspire.slnx`](https://github.com/grate-devs/grate/blob/main/grate.aspire.slnx) isolates the prototype from the core
provider matrix and release-package inventory. Build it, run the model tests,
then execute the example's smoke script. See its README for commands and cleanup.
[`Verify-AspirePackage.ps1`](https://github.com/grate-devs/grate/blob/main/scripts/Verify-AspirePackage.ps1) also restores and
executes a separate consumer of a locally packed library. The dedicated Aspire
workflow performs these checks for all three providers without publishing packages.
It bootstraps the native CLI/bundle before building. The reusable
[`Install-AspireCli.ps1`](https://github.com/grate-devs/grate/blob/main/scripts/Install-AspireCli.ps1)
pins 13.6.5 and verifies the release archive's SHA512 checksum. It accepts
`linux-x64` or `osx-arm64` and a new destination directory, then returns `CliPath`
and `BundlePath` for the `AspireCliPath`/`AspireCliBundlePath` build settings.

The repository's SDK selection stays unchanged. The documented stable .NET 10
fallback can check the net10-only adapter from outside the checkout; it does not
establish compatibility with other frameworks. See the
[integration assessment](design/aspire-integration.md) for design and scope.
