# Azure Container Apps migration init container

This checkout example uses the unpublished `grate.aspire.azure` package with
Aspire 13.6.5 and .NET 10. The API depends on an existing PostgreSQL database.
Locally, the helper waits for a successful grate migration. When publishing to
Azure Container Apps, the same helper puts grate in the API's init containers
and packages the SQL in a derived `gratedevs/grate:2.3.0` image.

The example does not provision PostgreSQL. Supply `ConnectionStrings:appdb`
through secret configuration, using an endpoint reachable from the migration
container and API. A host-only `localhost` address is generally insufficient.
For deployment, arrange Azure connectivity and runtime secrets for that existing
database separately.

## Application wiring

The shared model declares an ACA environment in publish mode, then configures:

```csharp
using Grate.Aspire.Azure;
using Grate.Aspire.Hosting;

var database = builder.AddConnectionString("appdb");
var migration = database.AddGrateMigration(
        GrateDatabaseProvider.PostgreSql, waitForDatabase: false)
    .WithScriptsFolder("../db");

builder.AddProject<Projects.Api>("api")
    .WithReference(database)
    .WithGrateMigrationInitContainer(migration, environment: "PRODUCTION");
```

Call `WithGrateMigrationInitContainer` on the application after configuring the
migration's SQL folder and base image. `environment` is mandatory: this example
uses grate's `PRODUCTION` environment in the deployed init container and leaves
the shared local migration at `LOCAL`. This setting is independent of the
Aspire CLI's `--environment` deployment configuration.

The native publisher builds and pushes the migration image before provisioning
the API's Container App. There is no separate migration Container App or manual
job to execute. The init template retains the launcher, migration arguments and
deferred `APP_CONNSTRING` secret reference. Literal connection strings and
connection parameters with published default values are rejected.

The SQL snapshot contains only `.sql` files, with their relative paths and bytes
preserved. Non-SQL configuration files are excluded; symbolic links and extra
runtime mounts are rejected. The AppHost owns the temporary Docker build context.
Use the native pipeline while that AppHost is alive; a legacy manifest export
does not provide a portable build context for a later independent process.

## Run locally or generate publication artifacts

Use the repository's SDK and a .NET 10 runtime, Docker, PowerShell 7 and the
native Aspire 13.6.5 CLI/bundle. The reusable
[`Install-AspireCli.ps1`](../../../scripts/Install-AspireCli.ps1) installs the
pinned CLI into a new directory and verifies its archive checksum. Its returned
`CliPath` and `BundlePath` can be supplied as `AspireCliPath` and
`AspireCliBundlePath` for AppHost builds.

From the repository root, configure a local secret and run with the native CLI:

```powershell
aspire secret set 'ConnectionStrings:appdb' '<your PostgreSQL connection string>' --apphost examples/aspire/AzureContainerApps/AppHost/AppHost.csproj
aspire run --apphost examples/aspire/AzureContainerApps/AppHost/AppHost.csproj
```

This starts a real migration against the database you configured. The API's `/`
endpoint reads the seed row after successful migration. The example SQL includes
separate `ENV.LOCAL` and `ENV.PRODUCTION` seed files to show the environment
selection.

Generate the native deployment artifacts without deploying to Azure:

```powershell
aspire publish --apphost examples/aspire/AzureContainerApps/AppHost/AppHost.csproj --output-path /absolute/path/to/local/aca-artifacts
```

Review Bicep, secret parameters and the pipeline before choosing a real
deployment. `aspire deploy --apphost examples/aspire/AzureContainerApps/AppHost/AppHost.csproj`
runs the native deployment pipeline and can create or modify Azure resources;
it requires your Azure subscription, authentication, database connectivity and
deployment secret configuration. The local publication checks below do not
perform that deployment.

The checkout's `global.json` still selects .NET 11. With only .NET 10 installed,
follow the [stable-SDK fallback](../../../CONTRIBUTING.md#working-with-the-stable-net-10-sdk)
for direct project builds from outside the checkout using absolute paths. The
verification script handles its own temporary working directory.

## Verify publication offline

Run from any directory with the prerequisites above:

```powershell
pwsh -NoProfile -File /absolute/path/to/scripts/Verify-AspirePublication.ps1
```

The script builds and runs `PublicationChecks`, which uses the same application
model and native Aspire publisher. It checks that:

- Bicep contains the migration init container, secure connection references and
  the explicit `PRODUCTION` environment, without a standalone migration app/job.
- The native pipeline includes a migration image build and push, and the API's
  actual provisioning step depends on that push.
- The derived grate image executes its packaged SQL and selects the production
  fixture while excluding the local fixture.

The image execution uses a disposable local SQLite file with portable SQL to
verify packaging and environment selection. This is not SQLite cloud support
and does not test PostgreSQL or an Azure-hosted database. The checks do not call
Azure, push to a registry, provision resources or run a real ACA replica. Keep
point-in-time artifacts and logs outside the checkout.

## Replica startup and remaining limits

ACA runs init containers for every replica startup, including scale-out and
restarts. A failed init blocks that replica's main containers; this is not a
once-per-deployment gate or a database-wide migration lock. Replicas, applications
and independent deployments can race. Serialize migrations for a shared database
or coordinate their deployment externally. Everytime scripts can run again.
Cancellation and failure do not guarantee rollback of previously committed SQL.

SQLite publishing is rejected because the local shared-file adapter does not
define durable storage, shared paths and filesystem locking for cloud replicas.
Kubernetes init containers use the separate
[`grate.aspire.kubernetes` adapter](../Kubernetes/README.md). There is no separate
migration Job lifecycle or Azure App Service predeployment adapter.
See the [integration guide](../../../docs/Aspire.md) for those boundaries.
