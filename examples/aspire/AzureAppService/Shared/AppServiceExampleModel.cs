using Aspire.Hosting;
using Aspire.Hosting.ApplicationModel;
using Aspire.Hosting.Azure;
using Aspire.Hosting.Azure.AppContainers;
using Grate.Aspire.AppService;
using Grate.Aspire.Hosting;

namespace Grate.Aspire.Example.AzureAppService;

internal static class AppServiceExampleModel
{
    internal static AppServiceExampleResources Configure(IDistributedApplicationBuilder builder, string scriptsDirectory = "../db")
    {
        // This database already exists. Both compute environments need a route to it.
        var database = builder.AddConnectionString("appdb");
        var migration = database.AddGrateMigration(GrateDatabaseProvider.PostgreSql, waitForDatabase: false)
            .WithScriptsFolder(scriptsDirectory);
        var api = builder.AddProject<Projects.Api>("api")
            .WithEnvironment("DatabaseProvider", "postgresql")
            .WithReference(database)
            .WithHttpEndpoint(name: "http")
            .WithExternalHttpEndpoints();
        if (builder.ExecutionContext.IsPublishMode)
        {
            var website = builder.AddAzureAppServiceEnvironment("webapps");
            var jobs = builder.AddAzureContainerAppEnvironment("jobs");
            api.WithComputeEnvironment(website)
                .WithGrateMigrationBeforeDeploy(migration, jobs, environment: "PRODUCTION");
        }
        else
        {
            api.WaitForCompletion(migration);
        }
        return new AppServiceExampleResources(migration, api);
    }
}

internal sealed record AppServiceExampleResources(
    IResourceBuilder<GrateMigrationResource> Migration,
    IResourceBuilder<ProjectResource> Api);
