# Run grate before deploying to Azure App Service

This example uses the unpublished `grate.aspire.appservice` adapter with
Aspire 13.6.5 and .NET 10. A manual Azure Container Apps Job migrates an
existing PostgreSQL database before Aspire creates or updates the web app.

```csharp
using Grate.Aspire.AppService;
using Grate.Aspire.Hosting;

var database = builder.AddConnectionString("appdb");
var migration = database.AddGrateMigration(GrateDatabaseProvider.PostgreSql, waitForDatabase: false)
    .WithScriptsFolder("../db");

var api = builder.AddProject<Projects.Api>("api")
    .WithReference(database)
    .WithHttpEndpoint(name: "http")
    .WithExternalHttpEndpoints();

if (builder.ExecutionContext.IsPublishMode)
{
    var websites = builder.AddAzureAppServiceEnvironment("webapps");
    var jobs = builder.AddAzureContainerAppEnvironment("jobs");
    api.WithComputeEnvironment(websites)
        .WithGrateMigrationBeforeDeploy(migration, jobs, environment: "PRODUCTION");
}
else
{
    api.WaitForCompletion(migration);
}
```

Aspire builds and pushes the image containing the SQL, provisions the job and
starts it. The gate follows the specific execution it started. The website
provisioning step can run after that execution succeeds. A job error or a
timeout fails the deployment. Locally the API waits for the grate container
to complete, as in the other examples.

The job runs with one replica and zero replica retries. The gate waits up to
30 minutes by default. Use the helper's `timeout` argument to change that limit.

Supply `ConnectionStrings:appdb` through secret configuration. The connection
must work from the Azure Container Apps environment and the App Service app.
For a private database, configure network access for both environments. The
deployment identity needs access to start the job and read its executions in
addition to the permissions required by Aspire's Azure provisioning. The
job receives the migration connection as a secret reference.

From the repository root with the pinned Aspire CLI and the Azure context
configured, publish or deploy the AppHost:

```powershell
aspire publish --apphost examples/aspire/AzureAppService/AppHost/AppHost.csproj
aspire deploy --apphost examples/aspire/AzureAppService/AppHost/AppHost.csproj
```

`aspire publish` generates artifacts. The job runs as part of `aspire deploy`.
The adapter rejects an attempt to publish a shared-file SQLite migration.

During an upgrade the existing app can keep serving traffic while the schema
changes. Use changes that the existing version can still read and write until
the new version is active. Serialize deployments that share a job or a database.
After a cancelled deployment, timeout or lost connection, inspect the job's
execution history before retrying. An execution that Azure already accepted may
still be running.

## Verify locally

With PowerShell 7 and Docker available, run:

```powershell
./scripts/Verify-AspireAppServicePublication.ps1
```

The verifier inspects native Aspire Bicep and the dependency on the actual
website provisioning step. It replays that part of the dependency graph with
Aspire's scheduler and the production gate action, using a local Docker run of
the packaged grate image in place of the Azure job. Successful SQL allows the
website step to run. Deliberately invalid SQL produces nonzero exit and a
migration error row, and the website step is never entered. Azure provisioning
calls are represented by test markers.
