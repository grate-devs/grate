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

## Existing server databases and portable script images

For a connection-string parameter or managed database resource, select the
provider explicitly instead of inferring it from the connection string:

```csharp
var database = builder.AddConnectionString("appdb");
var migration = database
    .AddGrateMigration(provider: GrateDatabaseProvider.PostgreSql)
    .WithScriptsFolder("db")
    .PublishAsGrateMigrationImage();
```

The enum also supports `SqlServer`, `Oracle`, `MySql` and `MariaDb`; the last two
select grate's `mariadb` backend. Optional `grate.aspire.oracle` and
`grate.aspire.mysql` packages add typed native database overloads. The target database must
already exist; creation stays disabled. The explicit-provider overload does not
support SQLite connection strings without the typed shared-file storage contract.

`PublishAsGrateMigrationImage` affects publish mode only. It snapshots `.sql`
files, preserving their relative paths and bytes, into a separate temporary build
context and derives an image from the configured grate image, registry and tag or
digest. Files such as `.env`, source Dockerfiles and `.dockerignore` are excluded.
SQL scripts are image content: do not embed deployment credentials in SQL.
Connection strings remain runtime environment/secret references.

Local runs keep their bind mount. Published resources have no runtime scripts
bind mount. Configure scripts and the base image before packaging; changing the
scripts afterward, symbolic links, additional runtime mounts and competing
Dockerfile builds are rejected. Shared-file SQLite requires a separate cloud
storage design and is rejected in publish mode. This helper packages an image;
the deployment target must still provide the migration lifecycle. The optional
`grate.aspire.azure` adapter attaches an init container to a specific ACA
application with `.WithGrateMigrationInitContainer(migration, environment: "PRODUCTION")`.
It runs before each replica's main containers and does not serialize migrations
across replicas or deployments. The optional `grate.aspire.kubernetes` adapter
offers the same binding from the `Grate.Aspire.Kubernetes` namespace for native
Kubernetes Helm publishing. It runs as an init container per Pod, preserves native
image build/push and waits for that push before Helm deployment. Import the
namespace for the chosen target; use the explicit target class when both adapters
are in scope. The native pipeline must build while the
AppHost-owned temporary SQL context is alive; a legacy manifest export alone
does not preserve that context for an independent later build.
