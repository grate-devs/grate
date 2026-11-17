# SQLite migrations in Aspire

This source-only prototype uses `CommunityToolkit.Aspire.Hosting.Sqlite` 13.6.1
with Aspire 13.6.5 and `gratedevs/grate:2.3.0`. The hosting package is unpublished.

```csharp
var dataDirectory = Path.GetFullPath("../data", builder.AppHostDirectory);
var database = builder.AddSqlite("appdb", dataDirectory, "demo.db");
var migration = database.AddGrateMigration()
    .WithScriptsFolder("../db");
```

SQLite has no database server to start or wait for. The adapter mounts the
dedicated database directory writable in the migration container and maps the
file into its connection string. The host API references the original SQLite
resource and receives the host file path. It starts after
`WaitForCompletion(migration)` succeeds. Scripts still mount read-only.

On Linux, macOS and FreeBSD, the migration container runs with the AppHost's
effective user/group IDs so newly created SQLite files remain writable by the
host application. This does not change ownership or permissions of existing
files; existing data must already be writable by that identity. .NET bundle
extraction and grate's output use writable container-local
directories under `/tmp`, separate from the retained database directory.
Windows uses the container runtime's normal bind-mount ownership behavior.

Use a dedicated absolute directory and ordinary filename. In-memory, URI,
relative-file and shared temporary-root resources are unsupported.

## Run

Install the .NET 10 SDK and PowerShell 7 and start Docker for grate's container.
From this directory:

```powershell
dotnet run --project AppHost/AppHost.csproj --framework net10.0 --configuration Release
```

Find the API HTTP endpoint in the local Aspire dashboard and request `/`; it
should return `Hello from grate`. The database remains in the git-ignored
`data/demo.db` between runs. Stop the AppHost before removing `data` to reset it.

From any directory, verify with:

```powershell
pwsh -NoProfile -File /absolute/path/to/examples/aspire/Smoke.ps1 -Provider sqlite
```

The checks verify actual data, API response and one-time history on a fresh and
retained file. The host also inserts and reads a probe row in a transaction,
then rolls it back and verifies it is absent, proving write access without
changing retained seed data. Invalid SQL must record an error and block API
startup. Script,
database and mount paths contain spaces. The graph contains only the migration
container, with no fake SQLite server/readiness dependency. Owned temporary
files and containers are removed after each scenario.

See the [shared guide](../README.md) for customization and support boundaries.
This directory-sharing model is local orchestration, not a portable deployment
artifact.
