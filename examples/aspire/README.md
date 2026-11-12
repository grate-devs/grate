# Database migrations in Aspire

This checkout-based prototype implements the API proposed in
[#956](https://github.com/grate-devs/grate/issues/956). The five Aspire packages
have not been published. The examples run the released `gratedevs/grate:2.3.0`
image; AppHosts and APIs target .NET 10 with Aspire 13.6.5.

| Example | Adapter and database ownership |
| --- | --- |
| PostgreSQL, below | `grate.aspire.hosting`; native Aspire provisions the database |
| [SQL Server](SqlServer/README.md) | `grate.aspire.hosting`; native Aspire provisions the database |
| [SQLite](Sqlite/README.md) | `grate.aspire.hosting`; host and migration share a writable file directory |
| [Oracle](Oracle/README.md) | Optional `grate.aspire.oracle`; select an existing service/PDB, not a new database or user |
| [MySQL](MySql/README.md) | Optional `grate.aspire.mysql`; native Aspire provisions the database |
| [MariaDB](MariaDb/README.md) | The same MySQL adapter and native resource with a MariaDB image; native Aspire provisions the database |
| [Azure Container Apps](AzureContainerApps/README.md) | Optional `grate.aspire.azure`; an application init container uses packaged SQL and an existing external database |
| [Kubernetes](Kubernetes/README.md) | Optional `grate.aspire.kubernetes`; a Pod init container uses packaged SQL and an existing external database |

The consumer API is:

```csharp
var migration = database.AddGrateMigration()
    .WithScriptsFolder("../db");

builder.AddProject<Projects.Api>("api")
    .WithReference(database)
    .WaitForCompletion(migration);
```

The database resource supplies the connection, PostgreSQL provider and readiness
dependency. The migration defaults to a read-only `/db` script mount, environment
`LOCAL`, and database creation disabled because Aspire creates the database.
Application startup waits for successful migration completion. The API's `/`
endpoint queries the row inserted by the SQL fixture.

An external database resource can use an explicit provider instead:
`database.AddGrateMigration(GrateDatabaseProvider.PostgreSql)`. It must already be
provisioned. The provider is never inferred from the connection string. See the
[integration guide](../../docs/Aspire.md) for configuration and deployment limits.

## Run the PostgreSQL example

Install the repository's selected SDK and the .NET 10 runtime, plus PowerShell 7,
and start Docker. The first run pulls the PostgreSQL and grate images. Run the
following from `examples/aspire`:

```powershell
dotnet user-secrets set --project AppHost/AppHost.csproj 'Parameters:password' '<your-local-password>'
dotnet run --project AppHost/AppHost.csproj --framework net10.0 --configuration Release
```

The projects are net10-only, but the checkout's `global.json` still selects the
repository's .NET 11 SDK. With only the stable .NET 10 SDK installed, follow the
[documented fallback](../../CONTRIBUTING.md#working-with-the-stable-net-10-sdk):
run from outside the checkout and use absolute project paths. The smoke wrapper
below already builds and launches from a temporary working directory. Install
the pinned native Aspire CLI/bundle with
[`Install-AspireCli.ps1`](../../scripts/Install-AspireCli.ps1) when needed; pass
its returned `CliPath` and `BundlePath` through `AspireCliPath` and
`AspireCliBundlePath` for AppHost builds.

Use the Aspire dashboard link printed by the AppHost to find the API's HTTP
endpoint, then request `/`. It should return `Hello from grate`. The dashboard
is configured for local HTTP development in `launchSettings.json`.

This example uses the named volume `grate-aspire-example-postgres`. Keep the same
password when restarting it: a new password does not change an already
initialized PostgreSQL role. On a second run, grate checks its history and skips
the applied one-time fixture. Other grate script policies may execute again.

Stop the AppHost with Ctrl+C and wait for its containers to be removed. To discard
this example's local database, run:

```powershell
docker volume rm grate-aspire-example-postgres
```

## Customize a migration

Names, readiness and script settings are explicit API parameters. Use ordinary
Aspire methods for image and environment settings:

```csharp
var migration = database.AddGrateMigration(name: "custom-migrate")
    .WithScriptsFolder("../db", containerPath: "/sql", isReadOnly: true)
    .WithImage("gratedevs/grate", "2.3.0")
    .WithEnvironment("ENVIRONMENT", "TEST")
    .WithEnvironment("TRANSACTION", "true");
```

Relative script paths are resolved against the AppHost directory. Missing
directories fail configuration; repeated `WithScriptsFolder` calls replace the
previous scripts mount. `waitForDatabase: false` is an explicit advanced opt-out;
the caller must supply any replacement readiness policy.

The adapter launches `/bin/sh` and `exec /app/grate` with one set of generated
arguments, preserving the image's environment variable contract and forwarding
extra `WithArgs` arguments. Override images must supply those paths and CLI
semantics. Connection values remain deferred Aspire expressions until runtime.
Environment injection does not hide secrets from privileged process/container
inspection. Review diagnostics before sharing them.

## Verify the examples

From any directory:

```powershell
pwsh -NoProfile -File /absolute/path/to/examples/aspire/Smoke.ps1 -Provider postgresql
```

The script builds the smoke AppHost and API, launches from a temporary working
directory and prints one `PASS` line per completed scenario. It stores detailed
diagnostics in a temporary local log. `-NoBuild` reuses a matching Release build;
`-Scenario success` selects one scenario. Select `sqlite`, `sqlserver`, `oracle`,
`mysql`, or `mariadb` for another database. Run database suites sequentially on
a machine with limited Docker memory.

All six database examples check fresh migration effects, API reads, retained
one-time history/data, and a SQL failure that blocks API startup. Server examples
also check credential failures. PostgreSQL additionally exercises delayed
readiness and interruption. Individual provider READMEs describe image settings,
storage and cleanup.

The PostgreSQL checks use real disposable databases and the grate image:

- Fresh migration: actual table, row, one-time history and API HTTP response.
- Retained database: restart against the same volume and verify the same script
  history identity/hash and a single seeded row.
- Invalid SQL and invalid credentials: nonzero migration exit and API
  `FailedToStart`; SQL failure must leave a migration error row.
- Delayed readiness: PostgreSQL accepts a direct SQL probe while a custom
  readiness gate remains closed, with no migration container started. Opening
  the gate then permits the migration and API to complete normally.
- Interruption: observe an active `pg_sleep` migration, stop the AppHost and
  verify its migration and database containers are removed.

Every scenario uses script paths and a container mount target containing spaces,
checks the migration output for its generated database password, and removes its
own containers, volume and temporary SQL. Interruption does not establish a
rollback guarantee: inspect grate history and transaction policy before retrying
real interrupted migrations.

The database smoke checks establish local application graphs for their selected
engines. They do not establish compatibility across all host platforms and
container architectures or live Azure behavior. The
[ACA publication checks](AzureContainerApps/README.md#verify-publication-offline)
inspect native publication artifacts and execute packaged SQL locally, without
deploying to Azure.
