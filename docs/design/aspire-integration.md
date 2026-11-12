# Aspire integration assessment

Design for [#955](https://github.com/grate-devs/grate/issues/955) and
[#956](https://github.com/grate-devs/grate/issues/956).
This design has [unpublished database and ACA adapters](../Aspire.md) and a
[runnable example](https://github.com/grate-devs/grate/blob/main/examples/aspire/README.md). It is not a released
integration. Offline publication verification does not establish live Azure behavior.

## Recommendation

Use a small grate hosting package that extends an Aspire database resource with
`AddGrateMigration().WithScriptsFolder(scripts)`. The implementation includes
PostgreSQL, SQL Server and SQLite in the base package, optional native Oracle
and MySQL/MariaDB adapters, and an optional Azure Container Apps init-container
publisher. Runnable database examples and smoke checks verify the shared API.

The [maintainer's proposed API](https://github.com/grate-devs/grate/pull/957#discussion_r4543597501)
identifies the value: the database resource already supplies enough context to
infer the connection, provider and readiness dependency. The package can apply
grate's image, environment and script-mount conventions once, so consumers only
declare the script location and which applications must wait for completion.
This removes repeated configuration and gives those defaults a testable contract.
An example alone still makes every consumer maintain the same wiring.

Keep the package a thin adapter over the existing container contract, with
explicit overrides and no migration engine of its own. Package compatibility,
versioning and release maintenance are costs of this recommendation, to be
bounded by the pinned Aspire baseline, supported resource types and explicitly
implemented deployment adapter. Keep cloud orchestration separate from the base
database integration.

## Use cases and existing behavior

The primary user is a developer running an Aspire AppHost locally:

- On a fresh database, create the database, execute SQL, then start the API that
  expects the migrated schema. Database readiness alone is insufficient.
- With retained data, rerun grate using its existing history and script policies,
  then start the API. Everytime scripts still execute; a restart is not a promise
  that no SQL will run.
- With invalid SQL or credentials, keep the dependent API from starting and show
  the migration failure through the migration resource's exit status and output.
- With several consumers of one database, declare one migration resource and
  make each consumer wait for it, rather than migrate once per application.

grate already has a [PostgreSQL Compose example](https://github.com/grate-devs/grate/blob/main/examples/docker/postgresql/README.md)
and a [container entrypoint](https://github.com/grate-devs/grate/blob/main/installers/docker/entrypoint.sh) that accepts
`APP_CONNSTRING`, `DATABASE_TYPE`, and other migration settings. Its
[CLI](https://github.com/grate-devs/grate/blob/main/src/grate/Program.cs) returns zero after success and a nonzero result
after a migration exception. Aspire's
[completion dependency](https://aspire.dev/hub/glossary/waitforcompletion/)
waits for the expected exit code, zero by default. These existing boundaries are
enough to describe the intended orchestration without changing grate's core.

## Alternatives

| Approach | Benefit | Cost and limitation | Assessment |
| --- | --- | --- | --- |
| Generic container plus documented example | Reuses the shipped image, existing configuration and Aspire lifecycle APIs; separates AppHost and grate runtimes | Each consumer repeats provider, mount, environment and dependency wiring | Useful fallback and description of package internals |
| Dedicated hosting package | Infers database context and applies grate defaults through a short fluent API; validates and tests those conventions centrally | Own an Aspire dependency range, public API, package release, image-version policy and provider/lifecycle tests | Recommended first delivery, with a runnable example |
| Local CLI/executable resource | Uses an installed tool or checkout; avoids a second container for migrations | Tool/runtime installation, version selection, working directory, host networking and secret argument handling vary by machine | Useful documented alternative, outside the first example |
| Consumer-owned worker calling grate libraries | Full control over configuration and host lifecycle | Adds a project and couples the consumer's runtime, dependencies, logging and cancellation to grate's library API | Consider when application-specific migration code is already necessary |
| ACA application init container | Packages SQL and prevents a replica's primary containers from starting before successful migration | Runs on every replica startup; does not serialize database migrations across replicas or applications | Implemented as an optional adapter; requires deployment coordination |
| Separate delivery-pipeline migration | Explicit deployment gate, credentials and operational ownership | Does not itself provide local AppHost startup coordination | Retain when a once-per-deployment migration owner or cross-application serialization is required |

Aspire documents [external executable resources](https://aspire.dev/app-host/executable-resources/)
and [custom resource extension points](https://aspire.dev/extensibility/custom-resources/).
Keep the hosting package a thin AppHost adapter around the
container contract. Aspire dependencies must not enter grate's core or database
providers. Do not introduce an application client integration just to run a
finite migration job.

## Prototype package API

The extension methods below are implemented in
[`grate.aspire.hosting`](https://github.com/grate-devs/grate/blob/main/src/grate.aspire.hosting/NuGet.md)
and optional `grate.aspire.oracle` and `grate.aspire.mysql` packages, but are not
available in released packages. `database` is a supported native database or
toolkit SQLite resource; `scripts` identifies the consumer's SQL directory.

```csharp
var migration = database
    .AddGrateMigration()
    .WithScriptsFolder(scripts);

builder.AddProject<Projects.Api>("api")
    .WithReference(database)
    .WaitForCompletion(migration);
```

`AddGrateMigration` returns an Aspire resource builder for a finite
grate container resource, compatible with `WaitForCompletion` and normal
container customization. The caller still chooses which applications wait for
it; creating the migration must not add startup dependencies to every database
consumer implicitly.

| Setting | Prototype default | Override contract |
| --- | --- | --- |
| Aspire resource name | `<database-resource-name>-grate`; reject duplicate names | Explicit name for multiple named migration resources |
| Runtime container name | Aspire's generated name for the migration resource | Normal container-name customization; avoid a fixed global name that collides across AppHosts |
| Image and version | `gratedevs/grate` and a package-owned, tested release tag; initially use `2.3.0` | Explicit image/registry and tag or digest using a compatible entrypoint contract |
| Connection string | Database resource's deferred connection expression | Explicit deferred expression or runtime secret reference |
| Database type | Typed resource selects `postgresql`, `sqlserver`, `sqlite`, `oracle` or `mariadb`; the latter covers MySQL and MariaDB | Explicit provider for other connection resources, or `WithEnvironment("DATABASE_TYPE", ...)`; grate validates the value at invocation |
| Database creation | `CREATE_DATABASE=false`; native Aspire provisions PostgreSQL, SQL Server and MySQL/MariaDB databases. Oracle selects an existing service/PDB; SQLite uses a file-backed connection | Explicit creation setting; caller owns the altered creation/permission contract |
| Environment | `LOCAL` | Explicit grate environment selection |
| Script mount | `WithScriptsFolder` resolves the source against the AppHost directory, mounts read-only at `/db` | Explicit source, target and mount settings, keeping the CLI script path aligned with the target |
| Readiness dependency | Wait for server database resources; SQLite has no server wait | Explicit dependency/readiness override on server overloads |

The prototype uses normal container builder methods for image and environment
overrides. `AddGrateMigration(name, waitForDatabase)` controls naming and readiness;
`WithScriptsFolder(path, containerPath, isReadOnly)` controls the script mount.
The latter validates the source directory and replaces its earlier owned mount.
See the [usage guide](../Aspire.md) for concrete customization examples.

The package supplies a fixed shell launcher that executes `/app/grate` directly,
instead of appending conflicting options to the image's fixed `/db` entrypoint.
Script targets are positional arguments, never interpolated shell source. This
requires override images to contain `/bin/sh`, `/app/grate` and the compatible CLI
contract; a container with an arbitrary entrypoint is insufficient.

Typed overloads select the provider. An arbitrary resource exposing a connection
string does not reliably identify it, so the base package also accepts an
explicit `GrateDatabaseProvider` for `IResourceWithConnectionString` resources,
including `AddConnectionString`. Such databases must already be provisioned.
Neither a resource name nor a password should be recovered by parsing a rendered
connection string. Keep Aspire dependencies in the hosting package, outside the
grate core and database-provider libraries.

## Equivalent container wiring

This is a partial AppHost illustration, not a copy-and-run sample. `Projects.Api`
belongs to the consuming application, and `db/up` contains its PostgreSQL scripts.
This describes the default behavior encapsulated by the package. The prototype's
launcher also supports different script targets; the generic example below uses
the image's ordinary entrypoint and its fixed `/db` convention.

```csharp
var builder = DistributedApplication.CreateBuilder(args);

var database = builder.AddPostgres("postgres")
    .WithImageTag("16")
    .AddDatabase("appdb");

var scripts = Path.GetFullPath(Path.Combine(
    builder.AppHostDirectory, "db"));

var migration = builder.AddContainer("migrate", "gratedevs/grate", "2.3.0")
    .WithEnvironment("APP_CONNSTRING", database.Resource.ConnectionStringExpression)
    .WithEnvironment("DATABASE_TYPE", "postgresql")
    .WithEnvironment("CREATE_DATABASE", "false")
    .WithEnvironment("ENVIRONMENT", "LOCAL")
    .WithBindMount(scripts, "/db", isReadOnly: true)
    .WaitFor(database);

builder.AddProject<Projects.Api>("api")
    .WithReference(database)
    .WaitForCompletion(migration);

builder.Build().Run();
```

The ownership in this PostgreSQL illustration is explicit: Aspire provisions the
local database; grate migrates it. `CREATE_DATABASE=false` avoids a second
database-creation owner. Oracle's native `AddDatabase` instead selects a service
without creating a PDB or user; external connections also require an existing
database. `WithReference(database)` configures the API connection, while
`APP_CONNSTRING` maps the database expression to the existing grate entrypoint's
contract. Passing a reference alone does not supply that entrypoint variable.
The expression must remain deferred so Aspire resolves the correct address for
the consuming container; do not substitute a host-side `localhost` connection.

The image version above pins the [2.3.0 release](https://github.com/grate-devs/grate/releases/tag/2.3.0),
not every feature in the current checkout. The package should own and test its
default image version, with explicit consumer overrides. Update the tested tag
or digest deliberately; do not resolve `latest` automatically at runtime.

This illustration uses a fresh, ephemeral database. The retained-data example
must configure a PostgreSQL data volume and a stable password supplied through
secret configuration, and document how to remove that volume. Keep persistence
under the caller's database configuration; `AddGrateMigration` must not silently
change the database's lifetime. See Aspire's
[PostgreSQL hosting guidance](https://aspire.dev/integrations/databases/postgres/postgres-host/).

## Lifecycle, settings and failure contract

- Wait for database readiness before starting grate. Wait for successful grate
  completion before starting consumers. A completion wait on the database itself
  would wait for the wrong event.
- Preserve the migration process's nonzero exit result. Do not convert failure to
  a healthy resource, start consumers after a fixed delay, or silently retry SQL.
  A startup gate also does not stop an API that was already running when someone
  manually reruns a migration.
- Keep one migration owner per database during a run. Script history records
  execution; it does not establish a cross-AppHost migration lock. Concurrent
  AppHosts and production rollout serialization need an explicit owner.
- On cancellation or AppHost shutdown, stop the migration resource and withhold
  success. Do not promise graceful SQL cancellation or complete rollback:
  transaction and per-folder policies affect what may already have committed.
  Inspect history and failure output before retrying an interrupted migration.
- Mount a validated, existing script directory read-only, relative to the
  AppHost directory rather than the invoking shell. Scripts must match the named
  provider. Treat `/output` as ephemeral unless explicitly mounted for retention.
- Use runtime parameter/secret references for connection credentials, with no
  passwords in source, checked-in response files, or generated example output.
  The entrypoint expands `APP_CONNSTRING` into a CLI argument; environment
  injection is not a guarantee against process/container inspection. Verify
  failure logs and dashboard output before sharing diagnostics.
- Forward only documented settings. The container entrypoint already supplies
  noninteractive mode, `/db` and `/output`; it defaults migration version,
  environment, creation and transaction settings. The example should set its
  intended values explicitly; the package must apply its defaults and overrides
  deterministically and explain how additional CLI options are passed.
  See [configuration](../ConfigurationOptions/index.md) and
  [script policies](../ScriptTypes/index.md).
- Use console output and exit state as the first observability surface. A console
  process does not automatically become a source of structured Aspire traces or
  metrics. Keep secrets out of SQL tokens and verbose diagnostics as well.

## Compatibility and maintenance scope

Use an Aspire 13.6.x C# AppHost targeting `net10.0`, pinning the
AppHost SDK and hosting packages to 13.6.5. Aspire's [prerequisites](https://aspire.dev/get-started/prerequisites/)
require the .NET 10 SDK for C# AppHosts and a container runtime for container
resources. This baseline is separate from grate's
[library target frameworks](https://github.com/grate-devs/grate/blob/main/Directory.Build.props) and
[source-build SDK](https://github.com/grate-devs/grate/blob/main/global.json); it does not change either contract.
Building a repository-hosted example must account for the repository's SDK and
central package settings rather than silently inheriting unsuitable defaults.

PostgreSQL and SQL Server share deferred connection and database readiness wiring.
SQLite demonstrates the different shared-file boundary: writable database storage,
no server wait, container-path remapping and Unix file ownership. It uses toolkit
13.6.1 alongside Aspire 13.6.5. Optional Oracle and MySQL/MariaDB adapters use
native Aspire hosting packages at 13.6.5, preserving the same fluent API. MySQL
uses grate's existing `mariadb` provider; it does not introduce a new engine.
Oracle's example selects the existing `FREEPDB1` service and documents its SYSTEM
credentials and image initialization settings.

The optional ACA module packages SQL and configures init containers. Do not infer
other deployment-target support from local resource behavior; the
[deployment boundaries](../Aspire.md#other-deployment-boundaries) describe the
remaining Kubernetes, App Service and SQLite limitations.

The package's runnable example belongs with grate's consumer examples. Updates need a
small pinned compatibility matrix: Aspire/AppHost, grate image, database image,
host platform and container architecture. The package also needs a
chosen name and owner, supported Aspire range, public API compatibility checks,
release automation, and an image update policy independent of its own version.
Confirm release ownership and the supported dependency range before publication;
implementation and local package verification do not themselves publish it.
Do not rebuild or fork grate's migration implementation.

## Implemented examples and verification

[Issue #956](https://github.com/grate-devs/grate/issues/956) tracks the thin
hosting package, now exercised by six database AppHosts using its extension API,
with a minimal dependent API,
one-time SQL fixture, pinned dependencies, setup/cleanup instructions and a
repeatable PowerShell smoke check. Keep it outside the core provider tests.
First verify the resource model's inferred defaults, every advertised override,
name collisions, missing scripts and unsupported resource types. Then prove
these outcomes against disposable local resources:

1. Fresh database: SQL creates a table and seed row; the API starts afterward and
   returns that row. Assert actual database state as well as process success.
2. Retained database: restart without reapplying the one-time fixture; document
   that other script policies may run. Verify history and the seeded data.
3. Invalid SQL and invalid credentials: grate exits unsuccessfully and the API
   never starts within a bounded observation period; retain useful diagnostics.
4. Delayed readiness and interrupted migration: consumers cannot pass the gate
   early, and shutdown leaves no migration process running. Record interruption
   limits without interpreting a killed process as a successful migration.
5. Script path containing spaces and launch from another working directory:
   the same scripts are selected. Check diagnostics for credential disclosure.

The prototype includes resource-model tests, isolated consumption of all four
packed packages, and repeatable database smoke checks. PostgreSQL exercises all
the lifecycle boundaries above; other engines cover fresh setup, retained
data/history and SQL failure, with credential failures for server databases.
Do not infer interruption or delayed-readiness evidence for another engine from
the PostgreSQL scenarios. Keep actual
results, environment and limitations in the implementation PR. The earlier
container-only spike is not evidence for the extension API; use the new checks
when assessing the implementation.

## Azure Container Apps publication

The optional `grate.aspire.azure` package adds
`application.WithGrateMigrationInitContainer(migration, environment: "PRODUCTION")`.
It adds a successful local completion wait without changing the local migration's
`LOCAL` environment. In publish mode, it packages SQL in a derived grate image,
suppresses the standalone migration application, and adds an init container to
the consumer's ACA template. Native image build/push steps remain in the pipeline;
the actual consumer provisioning step depends on the migration image push.
The application must select its ACA environment first if several are available.

The deployment grate environment is explicit and belongs to the consumer binding.
It does not follow implicitly from the Aspire CLI's deployment environment.
Connections remain deferred secret references without published parameter
defaults. Configure the scripts and base image before invoking the helper.

The base `PublishAsGrateMigrationImage()` snapshots only `.sql` files, preserving
relative paths and bytes. It rejects symlinks, extra runtime mounts and the local
SQLite shared-file contract. Non-SQL configuration is not included. Aspire owns
the temporary build context for its live native pipeline; a legacy standalone
manifest export is not a portable build-context handoff after AppHost disposal.
Packaging alone does not create a startup gate for an arbitrary publisher.

The [ACA example](https://github.com/grate-devs/grate/blob/main/examples/aspire/AzureContainerApps/README.md)
uses an existing PostgreSQL connection and includes offline publication checks.
They exercise the native Bicep publisher and full pipeline dependencies, then
build the derived image and execute portable packaged SQL locally with SQLite,
including explicit production-versus-local environment selection. This proves
that publication structure and local packaged SQL execution are checked; it does
not establish a live registry push, Azure deployment or PostgreSQL execution in
ACA. Keep those evidence boundaries visible in reviews.

## Deployment ownership and remaining limits

ACA init containers run for every replica startup, including restarts and
scale-out. They block the replica's main containers on failure, but provide no
once-per-deployment guarantee or database-wide lock. Concurrent replicas,
applications and deployments can race. Serialize independent migrations for the
same database or coordinate deployments externally. History does not provide a
distributed lock, and everytime scripts may run on each invocation.

There is no Kubernetes init/Job adapter or Azure App Service predeployment
adapter. Use an explicitly executed and awaited migration job or delivery-pipeline
step for those targets. SQLite cloud publishing requires a separate durable
storage, path and locking contract and is explicitly rejected. Across targets,
define credentials, connectivity, migration ownership and interruption/retry
recovery. Keep migrations in an existing delivery pipeline when that already
provides the required ordering and serialization.
