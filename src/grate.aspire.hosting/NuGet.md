# grate Aspire hosting

Experimental PostgreSQL, SQL Server and SQLite hosting integration for Aspire
13.6.5 and .NET 10. SQLite uses CommunityToolkit.Aspire.Hosting.Sqlite 13.6.1.

```csharp
using Grate.Aspire.Hosting;

var database = builder.AddPostgres("postgres").AddDatabase("appdb");
var migration = database.AddGrateMigration().WithScriptsFolder("db");
builder.AddProject<Projects.Api>("api")
    .WithReference(database)
    .WaitForCompletion(migration);
```

The default image is `gratedevs/grate:2.3.0`. The adapter starts a finite
container, infers the provider, sets `CREATE_DATABASE=false` and environment
`LOCAL`, and mounts scripts read-only at `/db`. PostgreSQL and SQL Server
migrations wait for Aspire to provision their database before running.

For SQL Server, use the same extension on a SQL Server database resource:

```csharp
var database = builder.AddSqlServer("sqlserver").AddDatabase("appdb");
var migration = database.AddGrateMigration().WithScriptsFolder("db");
```

For SQLite, configure a dedicated absolute data directory:

```csharp
var dataDirectory = Path.Combine(builder.AppHostDirectory, "sqlite-data");
var database = builder.AddSqlite("appdb", dataDirectory, "app.db");
var migration = database.AddGrateMigration().WithScriptsFolder("db");
```

The SQLite adapter reads the resource's public `DataSource` property. It mounts
the whole parent directory read-write at `/grate-data`, maps the migration
connection to that container path, and leaves the host-side connection exposed
to API consumers unchanged. The directory must also support SQLite journal/WAL
files. There is no SQLite server readiness dependency. In-memory, URI and
relative file paths are rejected, as is the toolkit's default shared temporary
directory. Paths containing a semicolon or surrounding whitespace are rejected
because the toolkit's unquoted host connection cannot preserve them. The caller
owns persistence and cleanup. Configure a different data
mount target with `AddGrateMigration(containerDataPath: "/custom-data")`;
overlapping scripts and data mounts are rejected.

On Linux, macOS and FreeBSD, the SQLite migration uses the AppHost's effective
user and group IDs so newly created database, journal and WAL files remain
writable by the host API. It does not change existing file permissions.
Bundle extraction uses `/tmp/grate-bundle` and migration output uses
`/tmp/grate-output`, both inside the migration container. Windows uses the
container runtime's normal bind-mount permission handling.

Override resource naming/readiness for server databases through
`AddGrateMigration(name, waitForDatabase)`, script source/target/read-only settings through
`WithScriptsFolder`, and image or environment through standard Aspire builder
methods. `APP_CONNSTRING` accepts a deferred connection expression; no connection
string parsing is used. An override image must provide `/bin/sh` and `/app/grate`.
The adapter builds the CLI invocation directly rather than using the image's
fixed `/db` launcher. Additional nonconflicting CLI arguments can be appended
with `WithArgs`.

`VERSION`, `TRANSACTION` and `GRATE_OUTPUT_PATH` override the CLI version,
transaction and output settings, defaulting to `1.0.0`, `false` and `/output`
for server databases (`/tmp/grate-output` for SQLite).
The migration resource name defaults to `<database-resource-name>-grate`.
The database owns persistence and creation; API resources explicitly opt into
waiting for migration completion with `WaitForCompletion(migration)` for every
provider. Native connection overrides are explicit escape hatches; changing a
SQLite connection string does not relocate its automatically configured mount.
Local orchestration is not a production rollout mechanism.
