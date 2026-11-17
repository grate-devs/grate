// These tests exercise the adapter's pinned Aspire 13.6.5 deployment graph contract.
#pragma warning disable ASPIREPIPELINES001

using Aspire.Hosting;
using Aspire.Hosting.ApplicationModel;
using Aspire.Hosting.Azure;
using Aspire.Hosting.Azure.AppContainers;
using Aspire.Hosting.Pipelines;
using Azure.Core;
using Azure.Provisioning.AppContainers;
using Grate.Aspire.Azure;
using Grate.Aspire.Hosting;
using Microsoft.Extensions.DependencyInjection;
using Xunit;

namespace Grate.Aspire.Azure.Tests;

public sealed class InitContainerTests : IDisposable
{
    private readonly string _directory = Directory.CreateTempSubdirectory("grate-azure-").FullName;

    [Fact]
    public void Local_run_adds_only_the_explicit_completion_wait()
    {
        var builder = CreateBuilder(publish: false);
        var migration = CreateMigration(builder);
        var application = builder.AddContainer("api", "example/api", "1");

        application.WithGrateMigrationInitContainer(migration, environment: "PRODUCTION");

        var wait = Assert.Single(application.Resource.Annotations.OfType<WaitAnnotation>());
        Assert.Same(migration.Resource, wait.Resource);
        Assert.Equal(WaitType.WaitForCompletion, wait.WaitType);
        Assert.Equal(0, wait.ExitCode);
        Assert.Empty(migration.Resource.Annotations.OfType<DockerfileBuildAnnotation>());
        Assert.Empty(application.Resource.Annotations.OfType<AzureContainerAppCustomizationAnnotation>());
        Assert.Single(migration.Resource.Annotations.OfType<ContainerMountAnnotation>());
    }

    [Fact]
    public void Publish_packages_the_migration_without_a_standalone_application()
    {
        var builder = CreateBuilder();
        var environment = builder.AddAzureContainerAppEnvironment("environment");
        var migration = CreateMigration(builder);
        var application = builder.AddContainer("api", "example/api", "1");

        application.WithGrateMigrationInitContainer(migration, environment: "PRODUCTION");

        Assert.True(migration.Resource.RequiresImageBuildAndPush());
        Assert.Single(migration.Resource.Annotations.OfType<DockerfileBuildAnnotation>());
        Assert.Empty(migration.Resource.Annotations.OfType<ContainerMountAnnotation>());
        var target = Assert.Single(migration.Resource.Annotations.OfType<DeploymentTargetAnnotation>());
        Assert.Same(environment.Resource, target.ComputeEnvironment);
        Assert.Same(environment.Resource, target.ContainerRegistry);
        Assert.IsNotType<AzureContainerAppResource>(target.DeploymentTarget);
        Assert.Empty(target.DeploymentTarget.Annotations.OfType<PipelineStepAnnotation>());
        Assert.Single(application.Resource.Annotations.OfType<AzureContainerAppCustomizationAnnotation>());
    }

    [Fact]
    public void SQLite_is_rejected_instead_of_publishing_a_host_file_path()
    {
        var builder = CreateBuilder();
        builder.AddAzureContainerAppEnvironment("environment");
        var database = builder.AddSqlite("appdb", Path.Combine(_directory, "data"), "app.db");
        var migration = database.AddGrateMigration().WithScriptsFolder(Scripts());
        var application = builder.AddContainer("api", "example/api", "1");

        var error = Assert.Throws<NotSupportedException>(() => application.WithGrateMigrationInitContainer(migration, environment: "PRODUCTION"));

        Assert.Contains("SQLite", error.Message);
        Assert.Empty(migration.Resource.Annotations.OfType<DockerfileBuildAnnotation>());
    }

    [Fact]
    public void Missing_or_ambiguous_environment_is_rejected()
    {
        var builder = CreateBuilder();
        var migration = CreateMigration(builder);
        var application = builder.AddContainer("api", "example/api", "1");
        Assert.Throws<InvalidOperationException>(() => application.WithGrateMigrationInitContainer(migration, environment: "PRODUCTION"));
        builder.AddAzureContainerAppEnvironment("one");
        builder.AddAzureContainerAppEnvironment("two");
        Assert.Throws<InvalidOperationException>(() => application.WithGrateMigrationInitContainer(migration, environment: "PRODUCTION"));
    }

    [Fact]
    public void An_explicit_ACA_environment_resolves_an_ambiguous_model()
    {
        var builder = CreateBuilder();
        var selected = builder.AddAzureContainerAppEnvironment("one");
        builder.AddAzureContainerAppEnvironment("two");
        var migration = CreateMigration(builder);
        var application = builder.AddContainer("api", "example/api", "1").WithComputeEnvironment(selected);

        application.WithGrateMigrationInitContainer(migration, environment: "PRODUCTION");

        Assert.Same(selected.Resource, migration.Resource.GetDeploymentTargetAnnotation()?.ComputeEnvironment);
    }

    [Fact]
    public async Task Staging_preserves_secret_references_without_resolving_values()
    {
        var builder = CreateBuilder();
        builder.AddAzureContainerAppEnvironment("environment");
        var migration = CreateMigration(builder);
        var secret = builder.AddParameter("database-secret", secret: true);
        migration.WithEnvironment("APP_CONNSTRING", secret);
        var application = builder.AddContainer("api", "example/api", "1");
        application.WithGrateMigrationInitContainer(migration, environment: "PRODUCTION");
        var values = new Dictionary<string, object>();
        var context = new EnvironmentCallbackContext(builder.ExecutionContext, application.Resource, values, CancellationToken.None);

        foreach (var callback in application.Resource.Annotations.OfType<EnvironmentCallbackAnnotation>())
        {
            await callback.Callback(context);
        }

        Assert.Same(secret.Resource, values["GRATE_INIT_APPDB_GRATE_ENV_APP_CONNSTRING"]);
        Assert.Equal("postgresql", values["GRATE_INIT_APPDB_GRATE_ENV_DATABASE_TYPE"]);
        Assert.Contains("GRATE_INIT_APPDB_GRATE_ARG_0", values.Keys);
        Assert.DoesNotContain(values.Values, value => value is string text && text.Contains("Host=", StringComparison.Ordinal));
    }

    [Fact]
    public async Task Dynamic_arguments_are_rejected_instead_of_rendering_secrets_into_arguments()
    {
        var builder = CreateBuilder();
        builder.AddAzureContainerAppEnvironment("environment");
        var migration = CreateMigration(builder);
        var secret = builder.AddParameter("argument-secret", secret: true);
        migration.WithArgs(secret.Resource);
        var application = builder.AddContainer("api", "example/api", "1").WithGrateMigrationInitContainer(migration, environment: "PRODUCTION");
        var context = new EnvironmentCallbackContext(builder.ExecutionContext, application.Resource, new Dictionary<string, object>(), CancellationToken.None);

        await Assert.ThrowsAsync<NotSupportedException>(async () =>
        {
            foreach (var callback in application.Resource.Annotations.OfType<EnvironmentCallbackAnnotation>())
            {
                await callback.Callback(context);
            }
        });
    }

    [Fact]
    public void Consumer_provision_waits_for_the_migration_image_push()
    {
        var builder = CreateBuilder();
        var environment = builder.AddAzureContainerAppEnvironment("environment");
        var migration = CreateMigration(builder);
        var application = builder.AddContainer("api", "example/api", "1").WithGrateMigrationInitContainer(migration, environment: "PRODUCTION");
        var target = new AzureContainerAppResource("api-containerapp", _ => { }, application.Resource);
        application.Resource.Annotations.Add(new DeploymentTargetAnnotation(target) { ComputeEnvironment = environment.Resource });
        var push = new PipelineStep { Name = "push-migration", Action = _ => Task.CompletedTask, Resource = migration.Resource, Tags = [WellKnownPipelineTags.PushContainerImage] };
        var provision = new PipelineStep { Name = "provision-api", Action = _ => Task.CompletedTask, Resource = target, Tags = [WellKnownPipelineTags.ProvisionInfrastructure] };
        var other = new PipelineStep { Name = "provision-other", Action = _ => Task.CompletedTask, Resource = new ContainerResource("other"), Tags = [WellKnownPipelineTags.ProvisionInfrastructure] };
        using var services = builder.Services.BuildServiceProvider();
        var context = new PipelineConfigurationContext
        {
            Services = services,
            Model = new DistributedApplicationModel(builder.Resources),
            Steps = [push, provision, other]
        };

        foreach (var annotation in application.Resource.Annotations.OfType<PipelineConfigurationAnnotation>())
        {
            annotation.Callback(context);
        }

        Assert.Contains(push.Name, provision.DependsOnSteps);
        Assert.DoesNotContain(push.Name, other.DependsOnSteps);
    }

    [Fact]
    public void Native_secret_references_move_into_init_and_leave_the_primary_environment()
    {
        var builder = CreateBuilder();
        var migration = CreateMigration(builder);
        const string prefix = "GRATE_INIT_TEST_";
        var resource = new AzureProvisioningResource("application", infrastructure =>
        {
            var app = new ContainerApp("application")
            {
                Name = "application",
                EnvironmentId = new ResourceIdentifier("/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/test/providers/Microsoft.App/managedEnvironments/test")
            };
            var primary = new ContainerAppContainer { Name = "api", Image = "example/api:1" };
            primary.Env.Add(new ContainerAppEnvironmentVariable { Name = "APPLICATION_SETTING", Value = "retained" });
            primary.Env.Add(new ContainerAppEnvironmentVariable { Name = $"{prefix}ENV_APP_CONNSTRING", SecretRef = "native-secret" });
            primary.Env.Add(new ContainerAppEnvironmentVariable { Name = $"{prefix}ENV_DATABASE_TYPE", Value = "postgresql" });
            primary.Env.Add(new ContainerAppEnvironmentVariable { Name = $"{prefix}ARG_0", Value = "-c" });
            primary.Env.Add(new ContainerAppEnvironmentVariable { Name = $"{prefix}ARG_1", Value = "exec /app/grate" });
            app.Template.Containers.Add(primary);
            infrastructure.Add(app);

            GrateAzureContainerAppExtensions.ConfigureInitContainer(infrastructure, app, migration.Resource, prefix);

            Assert.Single(primary.Env);
            Assert.Equal("APPLICATION_SETTING", primary.Env[0].Value?.Name.Value);
            var init = Assert.Single(app.Template.InitContainers).Value;
            Assert.NotNull(init);
            Assert.Contains(init.Env, value => value.Value?.Name.Value == "APP_CONNSTRING" && value.Value.SecretRef.Value == "native-secret");
            Assert.Contains(init.Env, value => value.Value?.Name.Value == "DATABASE_TYPE" && value.Value.Value.Value == "postgresql");
            Assert.Equal(2, init.Args.Count);
        });

        var bicep = resource.GetBicepTemplateString();

        Assert.Contains("initContainers:", bicep);
        Assert.Contains("secretRef: 'native-secret'", bicep);
        Assert.DoesNotContain(prefix, bicep);
        Assert.Same(migration.Resource, Assert.IsType<ContainerImageReference>(resource.Parameters.Values.Single()).Resource);
    }

    [Fact]
    public void A_nonzero_completion_wait_is_rejected_before_image_or_consumer_mutation()
    {
        var builder = CreateBuilder();
        builder.AddAzureContainerAppEnvironment("environment");
        var migration = CreateMigration(builder);
        var application = builder.AddContainer("api", "example/api", "1").WaitForCompletion(migration, 1);

        Assert.Throws<InvalidOperationException>(() => application.WithGrateMigrationInitContainer(migration, environment: "PRODUCTION"));

        Assert.Empty(migration.Resource.Annotations.OfType<DockerfileBuildAnnotation>());
        Assert.Empty(application.Resource.Annotations.OfType<AzureContainerAppCustomizationAnnotation>());
        Assert.Equal(1, Assert.Single(application.Resource.Annotations.OfType<WaitAnnotation>()).ExitCode);
    }

    [Fact]
    public void Duplicate_attachment_is_rejected_early()
    {
        var builder = CreateBuilder();
        builder.AddAzureContainerAppEnvironment("environment");
        var migration = CreateMigration(builder);
        var application = builder.AddContainer("api", "example/api", "1").WithGrateMigrationInitContainer(migration, environment: "PRODUCTION");

        Assert.Throws<InvalidOperationException>(() => application.WithGrateMigrationInitContainer(migration, environment: "STAGING"));

        Assert.Single(application.Resource.Annotations.OfType<WaitAnnotation>());
        Assert.Single(application.Resource.Annotations.OfType<AzureContainerAppCustomizationAnnotation>());
    }

    [Fact]
    public async Task Two_consumers_have_independent_cloud_environments_without_changing_the_local_migration()
    {
        var builder = CreateBuilder();
        builder.AddAzureContainerAppEnvironment("environment");
        var migration = CreateMigration(builder);
        var production = builder.AddContainer("production", "example/api", "1")
            .WithGrateMigrationInitContainer(migration, environment: "PRODUCTION");
        var staging = builder.AddContainer("staging", "example/api", "1")
            .WithGrateMigrationInitContainer(migration, environment: "STAGING");

        var productionValues = await EnvironmentValues(builder, production.Resource);
        var stagingValues = await EnvironmentValues(builder, staging.Resource);
        var localValues = await EnvironmentValues(builder, migration.Resource);

        Assert.Equal("PRODUCTION", productionValues["GRATE_INIT_APPDB_GRATE_ENV_ENVIRONMENT"]);
        Assert.Equal("STAGING", stagingValues["GRATE_INIT_APPDB_GRATE_ENV_ENVIRONMENT"]);
        Assert.Equal("LOCAL", localValues["ENVIRONMENT"]);
        Assert.Single(migration.Resource.Annotations.OfType<DockerfileBuildAnnotation>());
    }

    [Fact]
    public async Task A_literal_connection_is_rejected_without_including_its_value_in_the_error()
    {
        var builder = CreateBuilder();
        builder.AddAzureContainerAppEnvironment("environment");
        var migration = CreateMigration(builder).WithEnvironment("APP_CONNSTRING", "Host=database;Password=private-marker");
        var application = builder.AddContainer("api", "example/api", "1")
            .WithGrateMigrationInitContainer(migration, environment: "PRODUCTION");

        var error = await Assert.ThrowsAsync<InvalidOperationException>(() => EnvironmentValues(builder, application.Resource));

        Assert.DoesNotContain("private-marker", error.Message);
    }

    [Fact]
    public async Task A_connection_parameter_with_a_published_default_is_rejected()
    {
        var builder = CreateBuilder();
        builder.AddAzureContainerAppEnvironment("environment");
        var migration = CreateMigration(builder);
        var secret = builder.AddParameter("bad-secret", "private-marker", publishValueAsDefault: true);
        migration.WithEnvironment("APP_CONNSTRING", secret);
        var application = builder.AddContainer("api", "example/api", "1")
            .WithGrateMigrationInitContainer(migration, environment: "PRODUCTION");

        var error = await Assert.ThrowsAsync<InvalidOperationException>(() => EnvironmentValues(builder, application.Resource));

        Assert.DoesNotContain("private-marker", error.Message);
    }

    [Fact]
    public void A_prebuilt_primary_gets_registry_pull_access_for_its_private_init_image()
    {
        var builder = CreateBuilder();
        var environment = builder.AddAzureContainerAppEnvironment("environment");
        var migration = CreateMigration(builder);
        var resource = new AzureProvisioningResource("application", infrastructure =>
        {
            var app = new ContainerApp("application")
            {
                Name = "application",
                EnvironmentId = new ResourceIdentifier("/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/test/providers/Microsoft.App/managedEnvironments/test")
            };
            app.Identity.ManagedServiceIdentityType = global::Azure.Provisioning.Resources.ManagedServiceIdentityType.SystemAssigned;
            var primary = new ContainerAppContainer { Name = "api", Image = "example/api:1" };
            primary.Env.Add(new ContainerAppEnvironmentVariable { Name = "PREFIX_ENV_APP_CONNSTRING", SecretRef = "native-secret" });
            primary.Env.Add(new ContainerAppEnvironmentVariable { Name = "PREFIX_ARG_0", Value = "-c" });
            app.Template.Containers.Add(primary);
            infrastructure.Add(app);

            GrateAzureContainerAppExtensions.ConfigureInitContainer(infrastructure, app, migration.Resource, "PREFIX_", environment.Resource);

            Assert.Single(app.Configuration.Registries);
            Assert.Single(app.Identity.UserAssignedIdentities);
            Assert.Equal(global::Azure.Provisioning.Resources.ManagedServiceIdentityType.SystemAssignedUserAssigned,
                app.Identity.ManagedServiceIdentityType.Value);
        });

        var bicep = resource.GetBicepTemplateString();

        Assert.Contains("AZURE_CONTAINER_REGISTRY_ENDPOINT", bicep, StringComparison.OrdinalIgnoreCase);
        Assert.Contains("AZURE_CONTAINER_REGISTRY_MANAGED_IDENTITY_ID", bicep, StringComparison.OrdinalIgnoreCase);
        Assert.Same(migration.Resource, Assert.Single(resource.Parameters.Values.OfType<ContainerImageReference>()).Resource);
    }

    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public void Selected_registry_access_is_merged_without_losing_custom_entries_or_duplicating_native_credentials(bool hasNativeCredentials)
    {
        var builder = CreateBuilder();
        var environment = builder.AddAzureContainerAppEnvironment("environment");
        var migration = CreateMigration(builder);
        var resource = new AzureProvisioningResource("application", infrastructure =>
        {
            var app = new ContainerApp("application")
            {
                Name = "application",
                EnvironmentId = new ResourceIdentifier("/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/test/providers/Microsoft.App/managedEnvironments/test")
            };
            var custom = new ContainerAppRegistryCredentials { Server = "other.azurecr.io", Identity = "custom-identity" };
            app.Configuration.Registries.Add(custom);
            if (hasNativeCredentials)
            {
                var server = new BicepOutputReference("AZURE_CONTAINER_REGISTRY_ENDPOINT", environment.Resource).AsProvisioningParameter(infrastructure);
                var identity = new BicepOutputReference("AZURE_CONTAINER_REGISTRY_MANAGED_IDENTITY_ID", environment.Resource).AsProvisioningParameter(infrastructure);
                app.Configuration.Registries.Add(new ContainerAppRegistryCredentials { Server = server, Identity = identity });
            }
            var primary = new ContainerAppContainer { Name = "api", Image = "example/api:1" };
            primary.Env.Add(new ContainerAppEnvironmentVariable { Name = "PREFIX_ENV_APP_CONNSTRING", SecretRef = "native-secret" });
            primary.Env.Add(new ContainerAppEnvironmentVariable { Name = "PREFIX_ARG_0", Value = "-c" });
            app.Template.Containers.Add(primary);
            infrastructure.Add(app);

            GrateAzureContainerAppExtensions.ConfigureInitContainer(infrastructure, app, migration.Resource, "PREFIX_", environment.Resource);

            Assert.Equal(2, app.Configuration.Registries.Count);
            Assert.Contains(app.Configuration.Registries, value => ReferenceEquals(value.Value, custom));
            Assert.Single(app.Identity.UserAssignedIdentities);
        });

        var bicep = resource.GetBicepTemplateString();

        Assert.Contains("other.azurecr.io", bicep);
        Assert.Contains("AZURE_CONTAINER_REGISTRY_ENDPOINT", bicep, StringComparison.OrdinalIgnoreCase);
        Assert.Contains("AZURE_CONTAINER_REGISTRY_MANAGED_IDENTITY_ID", bicep, StringComparison.OrdinalIgnoreCase);
    }

    [Theory]
    [InlineData("none")]
    [InlineData("application")]
    [InlineData("migration")]
    public void Pipeline_configuration_rejects_retargeting_but_allows_the_initial_unprepared_target(string retarget)
    {
        var builder = CreateBuilder();
        var one = builder.AddAzureContainerAppEnvironment("one");
        var two = builder.AddAzureContainerAppEnvironment("two");
        var migration = CreateMigration(builder);
        var application = builder.AddContainer("api", "example/api", "1")
            .WithComputeEnvironment(one)
            .WithGrateMigrationInitContainer(migration, environment: "PRODUCTION");
        if (retarget == "application")
        {
            application.WithComputeEnvironment(two);
            var actualTarget = new AzureContainerAppResource("api-containerapp", _ => { }, application.Resource);
            application.Resource.Annotations.Add(new DeploymentTargetAnnotation(actualTarget) { ComputeEnvironment = two.Resource });
        }
        else if (retarget == "migration")
        {
            migration.WithComputeEnvironment(two);
        }
        using var services = builder.Services.BuildServiceProvider();
        var context = new PipelineConfigurationContext
        {
            Services = services,
            Model = new DistributedApplicationModel(builder.Resources),
            Steps = []
        };
        void Configure()
        {
            foreach (var annotation in application.Resource.Annotations.OfType<PipelineConfigurationAnnotation>())
            {
                annotation.Callback(context);
            }
        }

        if (retarget != "none")
        {
            var error = Assert.Throws<InvalidOperationException>(Configure);
            Assert.Contains("environment changed", error.Message);
        }
        else
        {
            // ACA legitimately materializes its consumer target in BeforeStart.
            Assert.Null(application.Resource.GetDeploymentTargetAnnotation(one.Resource));
            Configure();
        }
    }

    private static async Task<Dictionary<string, object>> EnvironmentValues(IDistributedApplicationBuilder builder, IResource resource)
    {
        var values = new Dictionary<string, object>();
        var context = new EnvironmentCallbackContext(builder.ExecutionContext, resource, values, CancellationToken.None);
        foreach (var callback in resource.Annotations.OfType<EnvironmentCallbackAnnotation>())
        {
            await callback.Callback(context);
        }
        return values;
    }

    private IDistributedApplicationBuilder CreateBuilder(bool publish = true) => DistributedApplication.CreateBuilder(
        new DistributedApplicationOptions
        {
            ProjectDirectory = _directory,
            DisableDashboard = true,
            Args = publish ? ["--publisher", "manifest", "--output-path", Path.Combine(_directory, "publish")] : []
        });

    private IResourceBuilder<GrateMigrationResource> CreateMigration(IDistributedApplicationBuilder builder) =>
        builder.AddConnectionString("appdb").AddGrateMigration(GrateDatabaseProvider.PostgreSql).WithScriptsFolder(Scripts());

    private string Scripts() => Directory.CreateDirectory(Path.Combine(_directory, "sql")).FullName;

    public void Dispose() => Directory.Delete(_directory, recursive: true);
}

#pragma warning restore ASPIREPIPELINES001
