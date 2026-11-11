---
title: Aspire PostgreSQL prototype
nav_order: 9
---

# Aspire PostgreSQL prototype

The experimental `grate.aspire.hosting` library targets `net10.0` and Aspire
hosting 13.6.5, with `gratedevs/grate:2.3.0` as its default image. It is not
published; the [runnable example](https://github.com/grate-devs/grate/blob/main/examples/aspire/README.md) references the
local project and includes a minimal API, SQL and opt-in Docker smoke checks.

## Use the extension

Given an Aspire PostgreSQL database resource and an existing script directory:

```csharp
using Grate.Aspire.Hosting;

var migrate = database
    .AddGrateMigration()
    .WithScriptsFolder(scripts);

builder.AddProject<Projects.Api>("api")
    .WithReference(database)
    .WaitForCompletion(migrate);
```

The extension accepts a `PostgresDatabaseResource` builder and derives its
deferred connection, provider and readiness dependency. It names the resource
`<database-resource-name>-grate`, sets `CREATE_DATABASE=false` because Aspire
creates the database, and defaults grate's environment to `LOCAL`.
Other database resource types have no overload.

`WithScriptsFolder` resolves paths against the AppHost directory, requires an
existing directory, and mounts it read-only at `/db`. Calling it again replaces
its previous script mount while preserving unrelated mounts. Omitting it prevents
the migration from starting. SQL validity is checked by grate during execution.

The consumer explicitly waits for exit code zero. Migration failure blocks its
initial startup; rerunning a migration does not stop an already running API.

## Overrides

The returned builder supports normal Aspire container customization:

```csharp
var migrate = database.AddGrateMigration("catalog-migrate")
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
`CREATE_DATABASE` and `GRATE_OUTPUT_PATH` (default `/output`). Keep connections as
deferred expressions or secret references for correct container networking.
Use `WithScriptsFolder` to change mount and CLI path together; its third argument
controls read-only mounting. Use `WithArgs` for additional CLI options rather
than repeating the launcher-owned settings. Provider and creation overrides
change the caller's connection/permission contract; only PostgreSQL is exercised.

`AddGrateMigration(waitForDatabase: false)` opts out of database readiness.
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

Database persistence remains caller-owned. Retained data needs an explicit volume
and stable runtime password. Migration output is ephemeral unless mounted.
Local completion waits and bind mounts do not establish production rollout support.

## Build and verification

[`grate.aspire.slnx`](https://github.com/grate-devs/grate/blob/main/grate.aspire.slnx) isolates the prototype from the core
provider matrix and release-package inventory. Build it, run the model tests,
then execute the example's smoke script. See its README for commands and cleanup.
[`Verify-AspirePackage.ps1`](https://github.com/grate-devs/grate/blob/main/scripts/Verify-AspirePackage.ps1) also restores and
executes a separate consumer of a locally packed library. The dedicated Aspire
workflow performs these checks without publishing packages.

The repository's SDK selection stays unchanged. The documented stable .NET 10
fallback can check the net10-only adapter from outside the checkout; it does not
establish compatibility with other frameworks. See the
[integration assessment](design/aspire-integration.md) for design and scope.
