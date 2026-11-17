// Inspecting the pinned native deployment graph requires the experimental pipeline API.
#pragma warning disable ASPIREPIPELINES001

using Aspire.Hosting;
using Aspire.Hosting.ApplicationModel;
using Aspire.Hosting.Azure;
using Aspire.Hosting.Pipelines;
using Grate.Aspire.Hosting;
using Microsoft.Extensions.DependencyInjection;
using Xunit;

namespace Grate.Aspire.AppService.Tests;

public sealed class DeploymentBindingTests : IDisposable
{
    private readonly string _directory = Directory.CreateTempSubdirectory("grate-appservice-").FullName;

    [Fact]
    public async Task Local_run_adds_a_completion_wait_and_keeps_the_local_environment_and_mount()
    {
        var builder = CreateBuilder(publish: false);
        var migration = AddMigration(builder);
        var jobs = builder.AddAzureContainerAppEnvironment("jobs");
        var application = builder.AddContainer("api", "example/api", "1").WaitForCompletion(migration)
            .WithGrateMigrationBeforeDeploy(migration, jobs, environment: "PRODUCTION");

        var wait = Assert.Single(application.Resource.Annotations.OfType<WaitAnnotation>());
        Assert.Same(migration.Resource, wait.Resource);
        Assert.Equal(WaitType.WaitForCompletion, wait.WaitType);
        Assert.Equal(0, wait.ExitCode);
        Assert.Equal("LOCAL", (await EnvironmentValues(builder, migration.Resource))["ENVIRONMENT"]);
        Assert.Empty(migration.Resource.Annotations.OfType<AzureContainerAppJobCustomizationAnnotation>());
        Assert.Empty(migration.Resource.Annotations.OfType<DockerfileBuildAnnotation>());
        Assert.Single(migration.Resource.Annotations.OfType<ContainerMountAnnotation>());
    }

    [Fact]
    public async Task Consumers_can_share_one_cloud_job_only_with_the_same_migration_settings()
    {
        var builder = CreateBuilder();
        var sites = builder.AddAzureAppServiceEnvironment("sites");
        var jobs = builder.AddAzureContainerAppEnvironment("jobs");
        var migration = AddMigration(builder);
        var first = builder.AddContainer("first", "example/api", "1")
            .WithGrateMigrationBeforeDeploy(migration, jobs, environment: "PRODUCTION");
        var originalPipelineSteps = migration.Resource.Annotations.OfType<PipelineStepAnnotation>().ToArray();
        var second = builder.AddContainer("second", "example/api", "1")
            .WithGrateMigrationBeforeDeploy(migration, jobs, environment: "PRODUCTION");
        var incompatible = builder.AddContainer("third", "example/api", "1");

        Assert.Throws<InvalidOperationException>(() => incompatible.WithGrateMigrationBeforeDeploy(migration, jobs, environment: "STAGING"));
        Assert.Throws<InvalidOperationException>(() => first.WithGrateMigrationBeforeDeploy(migration, jobs, environment: "PRODUCTION"));
        Assert.Single(migration.Resource.Annotations.OfType<AzureContainerAppJobCustomizationAnnotation>());
        Assert.Single(migration.Resource.Annotations.OfType<DockerfileBuildAnnotation>());
        Assert.Equal(originalPipelineSteps, migration.Resource.Annotations.OfType<PipelineStepAnnotation>());
        Assert.Same(sites.Resource, first.Resource.GetComputeEnvironment());
        Assert.Same(sites.Resource, second.Resource.GetComputeEnvironment());
        Assert.Same(jobs.Resource, migration.Resource.GetComputeEnvironment());
        Assert.Equal("PRODUCTION", (await EnvironmentValues(builder, migration.Resource))["ENVIRONMENT"]);
    }

    [Fact]
    public void Nonzero_wait_and_shared_SQLite_files_are_rejected_before_packaging()
    {
        var builder = CreateBuilder();
        builder.AddAzureAppServiceEnvironment("sites");
        var jobs = builder.AddAzureContainerAppEnvironment("jobs");
        var migration = AddMigration(builder);
        var sqlite = builder.AddSqlite("sqlite", Path.Combine(_directory, "data"), "app.db")
            .AddGrateMigration().WithScriptsFolder(Scripts());
        var api = builder.AddContainer("api", "example/api", "1").WaitForCompletion(migration, 1);

        Assert.Throws<InvalidOperationException>(() => api.WithGrateMigrationBeforeDeploy(migration, jobs, environment: "PRODUCTION"));
        Assert.Throws<NotSupportedException>(() => api.WithGrateMigrationBeforeDeploy(sqlite, jobs, environment: "PRODUCTION"));
        Assert.Empty(migration.Resource.Annotations.OfType<DockerfileBuildAnnotation>());
        Assert.Empty(sqlite.Resource.Annotations.OfType<DockerfileBuildAnnotation>());
        Assert.Equal(1, Assert.Single(api.Resource.Annotations.OfType<WaitAnnotation>()).ExitCode);
    }

    [Theory]
    [InlineData("literal")]
    [InlineData("public")]
    [InlineData("published-default")]
    [InlineData("composite")]
    public async Task The_whole_connection_must_be_a_secret_without_a_published_default(string kind)
    {
        const string canary = "private-connection-canary";
        var builder = CreateBuilder();
        builder.AddAzureAppServiceEnvironment("sites");
        var jobs = builder.AddAzureContainerAppEnvironment("jobs");
        var migration = AddMigration(builder);
        switch (kind)
        {
            case "literal":
                migration.WithEnvironment("APP_CONNSTRING", $"Host=example.invalid;Password={canary}");
                break;
            case "public":
                migration.WithEnvironment("APP_CONNSTRING", builder.AddParameter("unsafe-connection"));
                break;
            case "published-default":
                migration.WithEnvironment("APP_CONNSTRING", builder.AddParameter("unsafe-connection", canary, publishValueAsDefault: true));
                break;
            case "composite":
                var secret = builder.AddParameter("database-secret", secret: true);
                migration.WithEnvironment("APP_CONNSTRING", $"Host={secret};Password={canary}");
                break;
            default:
                throw new ArgumentOutOfRangeException(nameof(kind));
        }
        builder.AddContainer("api", "example/api", "1")
            .WithGrateMigrationBeforeDeploy(migration, jobs, environment: "PRODUCTION");

        var error = await Assert.ThrowsAsync<InvalidOperationException>(() => EnvironmentValues(builder, migration.Resource));

        Assert.Contains("deferred secret", error.Message);
        Assert.DoesNotContain(canary, error.ToString());
    }

    [Theory]
    [InlineData("none")]
    [InlineData("application")]
    [InlineData("migration")]
    [InlineData("environment-callback")]
    [InlineData("job-customization")]
    public async Task Late_configuration_changes_fail_closed_before_provisioning(string change)
    {
        var builder = CreateBuilder();
        builder.AddAzureAppServiceEnvironment("sites");
        var jobs = builder.AddAzureContainerAppEnvironment("jobs");
        var migration = AddMigration(builder);
        var api = builder.AddContainer("api", "example/api", "1")
            .WithGrateMigrationBeforeDeploy(migration, jobs, environment: "PRODUCTION");
        switch (change)
        {
            case "application":
                api.WithComputeEnvironment(builder.AddAzureAppServiceEnvironment("other-sites"));
                break;
            case "migration":
                migration.WithComputeEnvironment(builder.AddAzureContainerAppEnvironment("other-jobs"));
                break;
            case "environment-callback":
                migration.WithEnvironment("APP_CONNSTRING", "late-literal");
                break;
            case "job-customization":
                migration.PublishAsAzureContainerAppJob();
                break;
        }
        using var services = builder.Services.BuildServiceProvider();
        var context = new PipelineConfigurationContext { Services = services, Model = new DistributedApplicationModel(builder.Resources), Steps = [] };
        var configure = Assert.Single(api.Resource.Annotations.OfType<PipelineConfigurationAnnotation>()).Callback;

        if (change == "none")
        {
            // Native targets are absent during Aspire's first configuration pass.
            await configure(context);
        }
        else
        {
            var error = await Assert.ThrowsAsync<InvalidOperationException>(() => configure(context));
            Assert.Contains("changed after adding the grate gate", error.Message);
        }
    }

    private IDistributedApplicationBuilder CreateBuilder(bool publish = true) => DistributedApplication.CreateBuilder(new DistributedApplicationOptions
    {
        ProjectDirectory = _directory,
        DisableDashboard = true,
        Args = publish ? ["AppHost:Operation=publish", $"Pipeline:OutputPath={Path.Combine(_directory, "publish")}"] : []
    });

    private IResourceBuilder<GrateMigrationResource> AddMigration(IDistributedApplicationBuilder builder) =>
        builder.AddConnectionString("appdb").AddGrateMigration(GrateDatabaseProvider.PostgreSql).WithScriptsFolder(Scripts());

    private string Scripts() => Directory.CreateDirectory(Path.Combine(_directory, "sql")).FullName;

    private static async Task<Dictionary<string, object>> EnvironmentValues(IDistributedApplicationBuilder builder, IResource resource)
    {
        var values = new Dictionary<string, object>();
        var context = new EnvironmentCallbackContext(builder.ExecutionContext, resource, values, TestContext.Current.CancellationToken);
        foreach (var callback in resource.Annotations.OfType<EnvironmentCallbackAnnotation>())
        {
            await callback.Callback(context);
        }
        return values;
    }

    public void Dispose() => Directory.Delete(_directory, recursive: true);
}

#pragma warning restore ASPIREPIPELINES001
