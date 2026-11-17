using Aspire.Hosting;
using Aspire.Hosting.ApplicationModel;
using Grate.Aspire.Azure;
using Grate.Aspire.Hosting;

namespace Grate.Aspire.Example.AzureContainerApps;

internal static class AcaExampleModel
{
    internal static AcaExampleResources Configure(IDistributedApplicationBuilder builder)
    {
        if (builder.ExecutionContext.IsPublishMode)
        {
            builder.AddAzureContainerAppEnvironment("aca");
        }
        // This database already exists. Its credentials are supplied through configuration.
        var database = builder.AddConnectionString("appdb");
        var migration = database.AddGrateMigration(GrateDatabaseProvider.PostgreSql, waitForDatabase: false)
            .WithScriptsFolder("../db");
        var api = builder.AddProject<Projects.Api>("api")
            .WithEnvironment("DatabaseProvider", "postgresql")
            .WithReference(database)
            .WithHttpEndpoint(name: "http")
            .WithExternalHttpEndpoints()
            .WithGrateMigrationInitContainer(migration, environment: "PRODUCTION");
        return new AcaExampleResources(migration, api);
    }
}

internal sealed record AcaExampleResources(
    IResourceBuilder<GrateMigrationResource> Migration,
    IResourceBuilder<ProjectResource> Api);
