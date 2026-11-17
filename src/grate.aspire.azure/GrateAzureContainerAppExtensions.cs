// Aspire 13.6.5 exposes deployment image dependencies through this experimental API.
#pragma warning disable ASPIREPIPELINES001

using Aspire.Hosting;
using Aspire.Hosting.ApplicationModel;
using Aspire.Hosting.Azure;
using Aspire.Hosting.Azure.AppContainers;
using Aspire.Hosting.Pipelines;
using Azure.Provisioning;
using Azure.Provisioning.AppContainers;
using Azure.Provisioning.Expressions;
using Azure.Provisioning.Resources;
using Grate.Aspire.Hosting;

namespace Grate.Aspire.Azure;

/// <summary>Publishes grate migrations as Azure Container Apps init containers.</summary>
public static class GrateAzureContainerAppExtensions
{
    /// <summary>Runs a migration before this application's containers start locally and in ACA.</summary>
    /// <remarks>
    /// ACA runs an init container for every replica startup, not once per deployment.
    /// Declare an ACA environment first, or select it on the application before this call.
    /// SQL scripts are packaged in a separate image; SQLite's local shared-file contract is unsupported.
    /// </remarks>
    public static IResourceBuilder<TApplication> WithGrateMigrationInitContainer<TApplication>(
        this IResourceBuilder<TApplication> application,
        IResourceBuilder<GrateMigrationResource> migration,
        string environment)
        where TApplication : IComputeResource, IResourceWithEnvironment, IResourceWithWaitSupport
    {
        ArgumentNullException.ThrowIfNull(application);
        ArgumentNullException.ThrowIfNull(migration);
        ArgumentException.ThrowIfNullOrWhiteSpace(environment);
        if (application.ApplicationBuilder != migration.ApplicationBuilder || ReferenceEquals(application.Resource, migration.Resource))
        {
            throw new ArgumentException("The application and migration must be distinct resources in the same AppHost.", nameof(migration));
        }
        if (migration.Resource.UsesSharedDatabaseFile)
        {
            throw new NotSupportedException("SQLite shared host files cannot be published as an Azure Container Apps init migration.");
        }
        if (application.Resource.Annotations.OfType<InitBinding>().Any(binding => binding.Migration == migration.Resource))
        {
            throw new InvalidOperationException("This application already has an init container for the migration.");
        }
        if (application.Resource.Annotations.OfType<WaitAnnotation>().Any(wait =>
            wait.Resource == migration.Resource && wait.WaitType == WaitType.WaitForCompletion && wait.ExitCode != 0))
        {
            throw new InvalidOperationException("An init migration cannot satisfy a consumer that expects a nonzero migration exit code.");
        }
        var computeEnvironment = application.ApplicationBuilder.ExecutionContext.IsPublishMode ? GetEnvironment(application) : null;
        application.Resource.Annotations.Add(new InitBinding(migration.Resource));
        if (!application.Resource.Annotations.OfType<WaitAnnotation>().Any(wait =>
            wait.Resource == migration.Resource && wait.WaitType == WaitType.WaitForCompletion && wait.ExitCode == 0))
        {
            application.WaitForCompletion(migration);
        }
        if (!application.ApplicationBuilder.ExecutionContext.IsPublishMode)
        {
            return application;
        }

        migration.PublishAsGrateMigrationImage();
        ConfigureImageTarget(migration, computeEnvironment ?? throw new InvalidOperationException("The ACA environment was not selected."));
        var prefix = $"GRATE_INIT_{migration.Resource.Name.Replace('-', '_').ToUpperInvariant()}_";
        application.WithEnvironment(context => StageMigration(context, migration.Resource, prefix, environment));
        application.WithAnnotation(new AzureContainerAppCustomizationAnnotation((infrastructure, app) =>
            ConfigureInitContainer(infrastructure, app, migration.Resource, prefix, computeEnvironment)));
        application.WithPipelineConfiguration(context =>
        {
            if (!ReferenceEquals(GetEnvironment(application), computeEnvironment))
            {
                throw new InvalidOperationException("The application's compute environment changed after configuring its grate init container. Select the environment before adding the migration binding.");
            }
            if (!ReferenceEquals(migration.Resource.GetComputeEnvironment(), computeEnvironment))
            {
                throw new InvalidOperationException("The migration image's compute environment changed after configuring its init-container binding. Configure a separate migration resource for another environment.");
            }
            var target = application.Resource.GetDeploymentTargetAnnotation(computeEnvironment)?.DeploymentTarget;
            if (target is not null)
            {
                if (target is not AzureContainerAppResource)
                {
                    throw new InvalidOperationException("The init-container consumer must be published as an Azure Container App.");
                }
                var pushes = context.GetSteps(migration.Resource, WellKnownPipelineTags.PushContainerImage).ToArray();
                var provisions = context.GetSteps(target, WellKnownPipelineTags.ProvisionInfrastructure).ToArray();
                if (provisions.Length != 0 && pushes.Length == 0)
                {
                    throw new InvalidOperationException("The migration image has no native image-push step; consumer provisioning is blocked.");
                }
                foreach (var provision in provisions)
                {
                    foreach (var push in pushes)
                    {
                        provision.DependsOn(push);
                    }
                }
            }
        });
        return application;
    }

    private static AzureContainerAppEnvironmentResource GetEnvironment<TApplication>(IResourceBuilder<TApplication> application)
        where TApplication : IResource
    {
        if (application.Resource.GetComputeEnvironment() is { } selected)
        {
            return selected as AzureContainerAppEnvironmentResource
                ?? throw new NotSupportedException("The grate init-container adapter supports Azure Container Apps only.");
        }
        var environments = application.ApplicationBuilder.Resources.OfType<AzureContainerAppEnvironmentResource>().ToArray();
        return environments.Length == 1 ? environments[0]
            : throw new InvalidOperationException("Declare one Azure Container Apps environment or explicitly select one on the application before configuring its grate init container.");
    }

    private static void ConfigureImageTarget(IResourceBuilder<GrateMigrationResource> migrationBuilder, AzureContainerAppEnvironmentResource environment)
    {
        var migration = migrationBuilder.Resource;
        if (migration.GetComputeEnvironment() is { } selected && selected != environment)
        {
            throw new InvalidOperationException("The migration image is assigned to another compute environment.");
        }
        if (migration.GetComputeEnvironment() is null)
        {
            migrationBuilder.WithComputeEnvironment(migrationBuilder.ApplicationBuilder.CreateResourceBuilder(environment));
        }
        if (migration.GetDeploymentTargetAnnotation() is { } existing)
        {
            if (existing.DeploymentTarget is not MigrationImageTarget || existing.ComputeEnvironment != environment)
            {
                throw new InvalidOperationException("The migration image is already bound to another deployment target or environment.");
            }
            return;
        }
        // Native ACA preparation skips targets already assigned to this environment.
        // Keep native image build/push annotations, with no standalone ACA application.
        migration.Annotations.Add(new DeploymentTargetAnnotation(new MigrationImageTarget(migration.Name))
        {
            ComputeEnvironment = environment,
            ContainerRegistry = environment
        });
    }

    internal static async Task StageMigration(EnvironmentCallbackContext context, GrateMigrationResource migration, string prefix, string environment)
    {
        if (context.EnvironmentVariables.Keys.Any(key => key.StartsWith(prefix, StringComparison.Ordinal)))
        {
            throw new InvalidOperationException("Application environment variables conflict with the grate init-container staging prefix.");
        }
        var values = new Dictionary<string, object>();
        var migrationEnvironment = new EnvironmentCallbackContext(context.ExecutionContext, migration, values, context.CancellationToken);
        foreach (var callback in migration.Annotations.OfType<EnvironmentCallbackAnnotation>())
        {
            await callback.Callback(migrationEnvironment);
        }
        // This setting belongs to the consumer binding; the shared local resource stays LOCAL.
        values["ENVIRONMENT"] = environment;
        if (!values.TryGetValue("APP_CONNSTRING", out var connection) || connection is string)
        {
            throw new InvalidOperationException("The ACA migration connection string requires a deferred secret reference rather than a literal value.");
        }
        ValidateNoPublishedDefaults(connection, new HashSet<object>(ReferenceEqualityComparer.Instance));
        foreach (var pair in values)
        {
            context.EnvironmentVariables.Add($"{prefix}ENV_{pair.Key}", pair.Value);
        }
        var arguments = new List<object>();
        var argumentContext = new CommandLineArgsCallbackContext(arguments, migration, cancellationToken: context.CancellationToken)
        {
            ExecutionContext = context.ExecutionContext
        };
        foreach (var callback in migration.Annotations.OfType<CommandLineArgsCallbackAnnotation>())
        {
            await callback.Callback(argumentContext);
        }
        for (var index = 0; index < arguments.Count; index++)
        {
            if (arguments[index] is not string argument)
            {
                throw new NotSupportedException("ACA init migration arguments must be literal strings; use environment references for secrets and dynamic values.");
            }
            context.EnvironmentVariables.Add($"{prefix}ARG_{index}", argument);
        }
    }

    internal static void ConfigureInitContainer(
        AzureResourceInfrastructure infrastructure, ContainerApp app, GrateMigrationResource migration, string prefix,
        AzureContainerAppEnvironmentResource? environment = null)
    {
        var primary = app.Template.Containers.FirstOrDefault()?.Value
            ?? throw new InvalidOperationException("The ACA application has no primary container to configure.");
        var init = new ContainerAppInitContainer
        {
            Name = migration.Name.ToLowerInvariant(),
            Image = new ContainerImageReference(migration).AsProvisioningParameter(infrastructure),
            Command = [migration.Entrypoint ?? "/bin/sh"],
            Resources = new AppContainerResources { Cpu = 0.5, Memory = "1Gi" }
        };
        var arguments = new SortedDictionary<int, string>();
        foreach (var item in primary.Env.ToArray())
        {
            var variable = item.Value;
            var name = variable?.Name.Value;
            if (variable is null || name is null || !name.StartsWith(prefix, StringComparison.Ordinal))
            {
                continue;
            }
            if (name.StartsWith($"{prefix}ENV_", StringComparison.Ordinal))
            {
                var originalName = name[($"{prefix}ENV_").Length..];
                if (originalName == "APP_CONNSTRING" && string.IsNullOrWhiteSpace(variable.SecretRef.Value))
                {
                    throw new InvalidOperationException("The ACA migration connection string must be supplied through a secret reference, without a literal published value.");
                }
                variable.Name = originalName;
                init.Env.Add(variable);
            }
            else if (name.StartsWith($"{prefix}ARG_", StringComparison.Ordinal)
                && int.TryParse(name[($"{prefix}ARG_").Length..], out var index)
                && variable.SecretRef.Value is null && variable.Value.Value is { } argument)
            {
                arguments.Add(index, argument);
            }
            else
            {
                throw new InvalidOperationException("Invalid grate init-container staging metadata.");
            }
            primary.Env.Remove(item);
        }
        if (arguments.Count == 0)
        {
            throw new InvalidOperationException("The grate init-container environment/arguments were not prepared by the ACA publisher.");
        }
        foreach (var argument in arguments.Values)
        {
            init.Args.Add(argument);
        }
        if (!init.Env.Any(value => value.Value?.Name.Value == "APP_CONNSTRING" && !string.IsNullOrWhiteSpace(value.Value.SecretRef.Value)))
        {
            throw new InvalidOperationException("The ACA migration requires a secret connection string environment reference.");
        }
        if (app.Template.InitContainers.Any(value => value.Value?.Name.Value == init.Name.Value))
        {
            throw new InvalidOperationException("The ACA template already contains an init container with this migration name.");
        }
        if (environment is not null)
        {
            EnsureRegistryAccess(infrastructure, app, environment);
        }
        app.Template.InitContainers.Add(init);
    }

    private static void EnsureRegistryAccess(AzureResourceInfrastructure infrastructure, ContainerApp app, AzureContainerAppEnvironmentResource environment)
    {
        // Use the same pinned 13.6.5 environment outputs and parameter names as the
        // native primary-container publisher, so existing native credentials deduplicate.
        var server = new BicepOutputReference("AZURE_CONTAINER_REGISTRY_ENDPOINT", environment).AsProvisioningParameter(infrastructure);
        var identity = new BicepOutputReference("AZURE_CONTAINER_REGISTRY_MANAGED_IDENTITY_ID", environment).AsProvisioningParameter(infrastructure);
        BicepValue<string> serverValue = server;
        BicepValue<string> identityValue = identity;
        var serverExpression = serverValue.Compile().ToString();
        var identityExpression = identityValue.Compile().ToString();
        var existing = app.Configuration.Registries.FirstOrDefault(value =>
            value.Value?.Server.Compile().ToString() == serverExpression)?.Value;
        if (existing is not null && existing.Identity.Compile().ToString() != identityExpression)
        {
            throw new InvalidOperationException("The selected ACA registry already has conflicting pull credentials. Configure one consistent registry identity before adding the migration init container.");
        }
        if (existing is null)
        {
            app.Configuration.Registries.Add(new ContainerAppRegistryCredentials { Server = server, Identity = identity });
        }
        if (app.Identity.ManagedServiceIdentityType.Value == ManagedServiceIdentityType.SystemAssigned)
        {
            app.Identity.ManagedServiceIdentityType = ManagedServiceIdentityType.SystemAssignedUserAssigned;
        }
        else if (app.Identity.ManagedServiceIdentityType.Value != ManagedServiceIdentityType.SystemAssignedUserAssigned)
        {
            app.Identity.ManagedServiceIdentityType = ManagedServiceIdentityType.UserAssigned;
        }
        var identityKey = BicepFunction.Interpolate($"{identity}").Compile().ToString();
        app.Identity.UserAssignedIdentities[identityKey] = new UserAssignedIdentityDetails();
    }

    private static void ValidateNoPublishedDefaults(object value, HashSet<object> visited)
    {
        if (!visited.Add(value))
        {
            return;
        }
        if (value is ParameterResource { Default: not null })
        {
            throw new InvalidOperationException("Migration connection parameters must not publish default values; supply runtime secrets instead.");
        }
        if (value is IValueWithReferences references)
        {
            foreach (var reference in references.References)
            {
                ValidateNoPublishedDefaults(reference, visited);
            }
        }
    }

    private sealed class MigrationImageTarget(string name) : Resource(name);
    private sealed class InitBinding(GrateMigrationResource migration) : IResourceAnnotation
    {
        internal GrateMigrationResource Migration { get; } = migration;
    }
}

#pragma warning restore ASPIREPIPELINES001
