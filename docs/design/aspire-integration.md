# Aspire integration assessment

Proposal for [#955](https://github.com/grate-devs/grate/issues/955).
This is an evaluation and a proposed first delivery, not an accepted architecture
decision or a supported Aspire integration.

## Recommendation

Proceed with a runnable PostgreSQL example using Aspire's existing container
resource APIs. Defer publishing a dedicated hosting package until the example
reveals repeated configuration or lifecycle problems that justify a public API.
The immediate benefit is a documented database → migration → application startup
sequence and one place to inspect migration status and console output.

A package would initially wrap image selection, a script mount, environment
variables, and dependencies. Those are useful defaults, but they do not yet
justify a new package compatibility and release commitment. Revisit that choice
if multiple consumers need the same validated configuration, additional providers
make the wiring cumbersome, or a deployment target requires reusable behavior.

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

grate already has a [PostgreSQL Compose example](../../examples/docker/postgresql/README.md)
and a [container entrypoint](../../installers/docker/entrypoint.sh) that accepts
`APP_CONNSTRING`, `DATABASE_TYPE`, and other migration settings. Its
[CLI](../../src/grate/Program.cs) returns zero after success and a nonzero result
after a migration exception. Aspire's
[completion dependency](https://aspire.dev/hub/glossary/waitforcompletion/)
waits for the expected exit code, zero by default. These existing boundaries are
enough to describe the intended orchestration without changing grate's core.

## Alternatives

| Approach | Benefit | Cost and limitation | Assessment |
| --- | --- | --- | --- |
| Generic container plus documented example | Reuses the shipped image, existing configuration and Aspire lifecycle APIs; separates AppHost and grate runtimes | Consumers declare provider, mount and environment mapping; image pulls and container runtime required | Start here |
| Dedicated hosting package | Can validate settings and offer common provider-specific defaults | Own an Aspire dependency range, public API, package release, image-version policy and provider/lifecycle tests | Defer until the example establishes recurring needs |
| Local CLI/executable resource | Uses an installed tool or checkout; avoids a second container for migrations | Tool/runtime installation, version selection, working directory, host networking and secret argument handling vary by machine | Useful documented alternative, outside the first example |
| Consumer-owned worker calling grate libraries | Full control over configuration and host lifecycle | Adds a project and couples the consumer's runtime, dependencies, logging and cancellation to grate's library API | Consider when application-specific migration code is already necessary |
| Separate delivery-pipeline migration | Explicit deployment gate, credentials and operational ownership | Does not itself provide local AppHost startup coordination | Retain for deployments; complementary to a local example |

Aspire documents [external executable resources](https://aspire.dev/app-host/executable-resources/)
and [custom resource extension points](https://aspire.dev/extensibility/custom-resources/).
If a hosting package is later justified, keep it a thin AppHost adapter around the
container contract. Aspire dependencies must not enter grate's core or database
providers. Do not introduce an application client integration just to run a
finite migration job.

## Proposed local usage

This is a partial AppHost illustration, not a copy-and-run sample. `Projects.Api`
belongs to the consuming application, and `db/up` contains its PostgreSQL scripts.
The follow-up example must pin and verify compatible Aspire packages and images,
including container-to-container connection-string resolution.

```csharp
var builder = DistributedApplication.CreateBuilder(args);

var database = builder.AddPostgres("postgres")
    .WithImageTag("16")
    .AddDatabase("appdb");

var scripts = Path.GetFullPath(Path.Combine(
    builder.AppHostDirectory, "db"));

var migrate = builder.AddContainer("migrate", "gratedevs/grate", "2.2.0")
    .WithEnvironment("APP_CONNSTRING", database.Resource.ConnectionStringExpression)
    .WithEnvironment("DATABASE_TYPE", "postgresql")
    .WithEnvironment("CREATE_DATABASE", "false")
    .WithEnvironment("ENVIRONMENT", "LOCAL")
    .WithBindMount(scripts, "/db", isReadOnly: true)
    .WaitFor(database);

builder.AddProject<Projects.Api>("api")
    .WithReference(database)
    .WaitForCompletion(migrate);

builder.Build().Run();
```

The proposed ownership is explicit: Aspire provisions the local database; grate
migrates that database. `CREATE_DATABASE=false` avoids a second database-creation
owner. `WithReference(database)` configures the API connection, while
`APP_CONNSTRING` maps the database expression to the existing grate entrypoint's
contract. Passing a reference alone does not supply that entrypoint variable.
The expression must remain deferred so Aspire resolves the correct address for
the consuming container; do not substitute a host-side `localhost` connection.

The image version above matches the existing Compose example. It is a proposed
example pin, not a claim that it contains every feature in the current checkout.
Select the tested release tag or digest when implementing the runnable example;
do not use `latest` as its reproducibility policy.

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
  intended values explicitly and explain how additional CLI options are passed.
  See [configuration](../ConfigurationOptions/index.md) and
  [script policies](../ScriptTypes/index.md).
- Use console output and exit state as the first observability surface. A console
  process does not automatically become a source of structured Aspire traces or
  metrics. Keep secrets out of SQL tokens and verbose diagnostics as well.

## Initial compatibility and maintenance scope

Propose an Aspire 13.6.x C# AppHost targeting `net10.0`, initially pinning the
AppHost SDK and hosting packages to 13.6.5. Aspire's [prerequisites](https://aspire.dev/get-started/prerequisites/)
require the .NET 10 SDK for C# AppHosts and a container runtime for container
resources. This proposed baseline is separate from grate's
[library target frameworks](../../Directory.Build.props) and
[source-build SDK](../../global.json); it does not change either contract.
Building a repository-hosted example must account for the repository's SDK and
central package settings rather than silently inheriting unsuitable defaults.

Start with PostgreSQL because an existing container example supplies a small
SQL fixture and an observable result. Consider SQL Server next after verifying
its connection expression, database readiness, TLS settings and an available
container architecture. Do not imply that all grate providers are supported by
this initial Aspire example. MariaDB/MySQL, Oracle and SQLite need separate
provider-specific examples and evidence; SQLite also has a shared-file boundary
instead of a database-server lifecycle.

The example would be maintained with grate's consumer examples. Updates need a
small pinned compatibility matrix: Aspire/AppHost, grate image, database image,
host platform and container architecture. A package would additionally need a
chosen name and owner, supported Aspire range, public API compatibility checks,
release automation, and an image update policy independent of its own version.
Neither route should rebuild or fork grate's migration implementation.

## Bounded first follow-up and verification

[Follow-up #956](https://github.com/grate-devs/grate/issues/956) tracks a
standalone PostgreSQL AppHost example with a minimal dependent API,
one-time SQL fixture, pinned dependencies, setup/cleanup instructions and a
repeatable PowerShell smoke check. Keep it outside the core provider tests.
The follow-up should prove these outcomes against disposable local resources:

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

This is a verification plan, not a record of executed checks. Link actual spike
and follow-up results from the issue or PR. A package decision can then use the
example's duplication and failure cases as evidence.

## Deployment boundary

The first delivery covers local orchestration only. A bind mount is not a
portable delivery artifact, and a local completion wait is not evidence of a
target platform's rollout ordering. For deployment, package versioned SQL with a
migration job or use the existing pipeline approach, supply deployment secrets,
serialize changes per database, and gate application rollout on job success.
Validate the specific publish target and recovery procedure separately before
advertising deployment support. Leave migration execution in the delivery
pipeline when that already provides the required ownership and ordering.
