# grate Aspire App Service integration

Prototype in this checkout; not a released package.

```csharp
using Grate.Aspire.AppService;
using Grate.Aspire.Hosting;

var database = builder.AddConnectionString("appdb");
var migration = database.AddGrateMigration(GrateDatabaseProvider.PostgreSql)
    .WithScriptsFolder("sql");
var api = builder.AddProject<Projects.Api>("api").WithReference(database);

if (builder.ExecutionContext.IsPublishMode)
{
    var sites = builder.AddAzureAppServiceEnvironment("sites");
    var jobs = builder.AddAzureContainerAppEnvironment("jobs");
    api.WithComputeEnvironment(sites)
        .WithGrateMigrationBeforeDeploy(migration, jobs, environment: "PRODUCTION");
}
else
{
    api.WaitForCompletion(migration);
}
```

Supply the whole migration connection through a deferred secret without a published
default. Configure the migration before binding it. Native Aspire publish generates
a manual Container Apps job and packages the SQL into its image. Native deploy
pushes the image, provisions the job, starts it once for this deployment, and
waits for that execution to succeed before provisioning the website. Running the
AppHost locally uses the usual completion wait and preserves its local environment.

The job uses one replica and no replica retries. The deployment deadline defaults
to 30 minutes and can be set with `timeout`. On failure, an unknown outcome, or
timeout, the website deployment is blocked; check the job execution before
retrying. Cancelling the wait does not stop an execution that Azure has started.
Configure database network access from the jobs environment and permission for
the Aspire deploy identity to start the job and read its execution. Independent
deployments can still overlap. SQLite shared host files are unsupported.
