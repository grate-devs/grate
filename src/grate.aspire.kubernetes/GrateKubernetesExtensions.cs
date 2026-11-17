// Aspire 13.6.5 exposes native deployment image dependencies through this experimental API.
#pragma warning disable ASPIREPIPELINES001

using System.Text.Json;
using System.Text.RegularExpressions;
using Aspire.Hosting;
using Aspire.Hosting.ApplicationModel;
using Aspire.Hosting.Kubernetes;
using Aspire.Hosting.Kubernetes.Resources;
using Aspire.Hosting.Pipelines;
using Grate.Aspire.Hosting;

namespace Grate.Aspire.Kubernetes;

/// <summary>Publishes grate migrations as Kubernetes init containers.</summary>
public static class GrateKubernetesExtensions
{
    /// <summary>Runs a migration before this application's containers start locally and in Kubernetes.</summary>
    /// <remarks>
    /// Kubernetes runs the init container for every pod startup, not once per deployment.
    /// Select a Kubernetes environment and registry before configuring the binding.
    /// SQLite shared host files cannot be published with this adapter.
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
            throw new NotSupportedException("SQLite shared host files cannot be published as a Kubernetes init migration.");
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

        var publish = application.ApplicationBuilder.ExecutionContext.IsPublishMode;
        var selected = publish ? GetEnvironment(application) : null;
        var registry = selected is null ? null : GetRegistry(application.ApplicationBuilder, selected);
        var binding = new InitBinding(migration.Resource, environment);
        application.WithAnnotation(binding);
        if (!application.Resource.Annotations.OfType<WaitAnnotation>().Any(wait =>
            wait.Resource == migration.Resource && wait.WaitType == WaitType.WaitForCompletion && wait.ExitCode == 0))
        {
            application.WaitForCompletion(migration);
        }
        if (!publish)
        {
            return application;
        }

        var targetEnvironment = selected ?? throw new InvalidOperationException("The Kubernetes environment was not selected.");
        migration.PublishAsGrateMigrationImage();
        ConfigureImageTarget(migration, targetEnvironment, registry!);
        application.WithEnvironment(context => StageMigration(context, binding));
        application.PublishAsKubernetesService(resource => ConfigureInitContainer(resource, binding));
        application.WithPipelineConfiguration(context =>
        {
            if (!ReferenceEquals(GetEnvironment(application), targetEnvironment)
                || !ReferenceEquals(migration.Resource.GetComputeEnvironment(), targetEnvironment))
            {
                throw new InvalidOperationException("The application's or migration's compute environment changed after configuring its grate init container. Select the environment before adding the binding.");
            }
            if (!ReferenceEquals(GetRegistry(application.ApplicationBuilder, targetEnvironment), registry)
                || !ReferenceEquals(migration.Resource.GetDeploymentTargetAnnotation(targetEnvironment)?.ContainerRegistry, registry))
            {
                throw new InvalidOperationException("The migration's container registry changed after configuring its init-container binding.");
            }
            // Native target preparation happens in BeforeStart, after the first configuration pass.
            if (application.Resource.GetDeploymentTargetAnnotation(targetEnvironment) is { } target)
            {
                if (target.DeploymentTarget is not KubernetesResource)
                {
                    throw new InvalidOperationException("The init-container consumer must be published as a Kubernetes workload.");
                }
                var pushes = context.GetSteps(migration.Resource, WellKnownPipelineTags.PushContainerImage).ToArray();
                var deployments = context.GetSteps(targetEnvironment, "helm-deploy").ToArray();
                if (deployments.Length != 0 && pushes.Length == 0)
                {
                    throw new InvalidOperationException("The migration image has no native image-push step; Helm deployment is blocked.");
                }
                foreach (var deployment in deployments)
                {
                    foreach (var push in pushes)
                    {
                        deployment.DependsOn(push);
                    }
                }
            }
        });
        return application;
    }

    private static KubernetesEnvironmentResource GetEnvironment<TApplication>(IResourceBuilder<TApplication> application)
        where TApplication : IResource
    {
        if (application.Resource.GetComputeEnvironment() is { } selected)
        {
            return selected as KubernetesEnvironmentResource
                ?? throw new NotSupportedException("The grate Kubernetes init-container adapter requires a native Kubernetes environment.");
        }
        var environments = application.ApplicationBuilder.Resources.OfType<KubernetesEnvironmentResource>().ToArray();
        return environments.Length == 1 ? environments[0]
            : throw new InvalidOperationException("Declare one Kubernetes environment or explicitly select one on the application before configuring its grate init container.");
    }

    private static IContainerRegistry GetRegistry(IDistributedApplicationBuilder builder, KubernetesEnvironmentResource environment)
    {
        if (environment.TryGetLastAnnotation<ContainerRegistryReferenceAnnotation>(out var selected))
        {
            return selected.Registry;
        }
        var registries = builder.Resources.OfType<IContainerRegistry>().ToArray();
        return registries.Length == 1 ? registries[0]
            : throw new InvalidOperationException("Select a container registry on the Kubernetes environment, or declare exactly one registry, before configuring the grate init container.");
    }

    private static void ConfigureImageTarget(IResourceBuilder<GrateMigrationResource> builder, KubernetesEnvironmentResource environment, IContainerRegistry registry)
    {
        var migration = builder.Resource;
        if (migration.GetComputeEnvironment() is { } selected && selected != environment)
        {
            throw new InvalidOperationException("The migration image is assigned to another compute environment.");
        }
        if (migration.GetDeploymentTargetAnnotation() is { } existing)
        {
            if (existing.DeploymentTarget is not MigrationImageTarget || existing.ComputeEnvironment != environment || existing.ContainerRegistry != registry)
            {
                throw new InvalidOperationException("The migration image is already bound to another deployment target, registry or environment.");
            }
            return;
        }
        builder.WithComputeEnvironment(builder.ApplicationBuilder.CreateResourceBuilder(environment));
        // The native publisher skips preassigned targets while native image build/push remains enabled.
        migration.Annotations.Add(new DeploymentTargetAnnotation(new MigrationImageTarget(migration.Name))
        {
            ComputeEnvironment = environment,
            ContainerRegistry = registry
        });
    }

    internal static async Task StageMigration(EnvironmentCallbackContext context, InitBinding binding)
    {
        var prefix = binding.Prefix;
        // Match native Helm path normalization as well as the physical environment key.
        if (context.EnvironmentVariables.Keys.Any(key => key.Replace('-', '_').StartsWith(prefix, StringComparison.OrdinalIgnoreCase)))
        {
            throw new InvalidOperationException("Application environment variables conflict with the grate init-container staging prefix.");
        }
        var values = new Dictionary<string, object>();
        var migrationContext = new EnvironmentCallbackContext(context.ExecutionContext, binding.Migration, values, context.CancellationToken);
        foreach (var callback in binding.Migration.Annotations.OfType<EnvironmentCallbackAnnotation>())
        {
            await callback.Callback(migrationContext);
        }
        values["ENVIRONMENT"] = binding.Environment;
        if (!values.TryGetValue("APP_CONNSTRING", out var connection) || connection is string)
        {
            throw new InvalidOperationException("The Kubernetes migration connection string requires a deferred secret reference rather than a literal value.");
        }
        ValidateNoPublishedDefaults(connection, new HashSet<object>(ReferenceEqualityComparer.Instance));
        foreach (var pair in values)
        {
            context.EnvironmentVariables.Add($"{prefix}ENV_{pair.Key}", pair.Value);
        }
        // Let the native publisher capture the deferred image value for Helm deployment overrides.
        context.EnvironmentVariables.Add($"{prefix}IMAGE", new ContainerImageReference(binding.Migration));
        var arguments = new List<object>();
        var argumentContext = new CommandLineArgsCallbackContext(arguments, binding.Migration, cancellationToken: context.CancellationToken)
        {
            ExecutionContext = context.ExecutionContext
        };
        foreach (var callback in binding.Migration.Annotations.OfType<CommandLineArgsCallbackAnnotation>())
        {
            await callback.Callback(argumentContext);
        }
        if (arguments.Any(argument => argument is not string))
        {
            throw new NotSupportedException("Kubernetes init migration arguments must be literal strings; use environment references for secrets and dynamic values.");
        }
        binding.Arguments = arguments.Cast<string>().ToArray();
    }

    internal static void ConfigureInitContainer(KubernetesResource resource, InitBinding binding)
    {
        if (resource.Workload is not Deployment and not StatefulSet)
        {
            throw new NotSupportedException("Grate init migrations support Kubernetes Deployments and StatefulSets only.");
        }
        var pod = resource.Workload.PodTemplate.Spec;
        if (pod.Containers.Count == 0 || binding.Arguments is not { Length: > 0 })
        {
            throw new InvalidOperationException("The Kubernetes publisher did not prepare the grate migration's arguments or primary container.");
        }
        var initName = binding.Migration.Name.ToLowerInvariant();
        if (pod.InitContainers.Any(container => container.Name == initName))
        {
            throw new InvalidOperationException("The workload already contains an init container with this migration name.");
        }
        var config = new ConfigMap();
        var secret = new Secret();
        config.Metadata.Name = $"{resource.Name}-{binding.Migration.Name}-init-config".ToLowerInvariant();
        secret.Metadata.Name = $"{resource.Name}-{binding.Migration.Name}-init-secret".ToLowerInvariant();
        if (new[] { config.Metadata.Name, secret.Metadata.Name }.Any(name => name.Length > 63)
            || resource.AdditionalResources.Any(item => item.Metadata.Name == config.Metadata.Name || item.Metadata.Name == secret.Metadata.Name)
            || resource.ConfigMap?.Metadata.Name == config.Metadata.Name || resource.Secret?.Metadata.Name == secret.Metadata.Name)
        {
            throw new InvalidOperationException("Grate init-container resource names conflict or exceed Kubernetes' 63-character name limit.");
        }
        var init = new ContainerV1 { Name = initName };
        init.Command.Add(binding.Migration.Entrypoint ?? "/bin/sh");
        init.Args.AddRange(binding.Arguments);
        if (resource.ConfigMap is { } appConfig)
        {
            if (!appConfig.Data.Remove($"{binding.Prefix}IMAGE", out var image))
            {
                throw new InvalidOperationException("The Kubernetes publisher did not prepare the deferred grate migration image.");
            }
            init.Image = image;
            MoveEnvironment(appConfig.Data, config.Data, config.Metadata.Name, init, binding, isSecret: false);
        }
        if (resource.Secret is { } appSecret)
        {
            MoveEnvironment(appSecret.StringData, secret.StringData, secret.Metadata.Name, init, binding, isSecret: true);
        }
        if (string.IsNullOrWhiteSpace(init.Image)
            || !init.Env.Any(variable => variable.Name == "APP_CONNSTRING" && variable.ValueFrom?.SecretKeyRef is not null))
        {
            throw new InvalidOperationException("The Kubernetes migration requires a deferred image and a secret connection string environment reference.");
        }
        QuoteTemplateScalars(config.Data);
        QuoteTemplateScalars(secret.StringData);
        // Pinned native templates otherwise surround ordinary expressions with literal
        // YAML quotes. A connection string containing quotes/backslashes would break
        // both the moved init secret and the consumer's own WithReference secret.
        // This native-recognized wrapper quotes the evaluated value, not the template.
        if (resource.ConfigMap is { } primaryConfig)
        {
            QuoteTemplateScalars(primaryConfig.Data);
        }
        if (resource.Secret is { } primarySecret)
        {
            QuoteTemplateScalars(primarySecret.StringData);
        }
        if (config.Data.Count > 0)
        {
            resource.AdditionalResources.Add(config);
        }
        resource.AdditionalResources.Add(secret);
        NormalizeHttpProbeSchemes(pod.Containers);
        pod.InitContainers.Add(init);
    }

    private static void NormalizeHttpProbeSchemes(IEnumerable<ContainerV1> containers)
    {
        // Pinned Aspire copies URI schemes as lowercase, but Kubernetes' HTTPGetAction
        // accepts only HTTP/HTTPS. Preserve custom templates and all other probe settings.
        foreach (var container in containers)
        {
            foreach (var probe in new[] { container.ReadinessProbe, container.LivenessProbe, container.StartupProbe })
            {
                if (probe?.HttpGet is not { } request)
                {
                    continue;
                }
                if (string.Equals(request.Scheme, "http", StringComparison.OrdinalIgnoreCase))
                {
                    request.Scheme = "HTTP";
                }
                else if (string.Equals(request.Scheme, "https", StringComparison.OrdinalIgnoreCase))
                {
                    request.Scheme = "HTTPS";
                }
            }
        }
    }

    private static void QuoteTemplateScalars(Dictionary<string, string> values)
    {
        foreach (var pair in values.ToArray())
        {
            if (pair.Value.Contains("{{", StringComparison.Ordinal)
                && !Regex.IsMatch(pair.Value, @"^\{\{\s*tpl\b.*\|\s*quote\s*\}\}$"))
            {
                values[pair.Key] = $"{{{{ tpl {JsonSerializer.Serialize(pair.Value)} . | quote }}}}";
            }
        }
    }

    private static void MoveEnvironment(Dictionary<string, string> source, Dictionary<string, string> destination,
        string name, ContainerV1 init, InitBinding binding, bool isSecret)
    {
        var prefix = $"{binding.Prefix}ENV_";
        foreach (var pair in source.Where(pair => pair.Key.StartsWith(prefix, StringComparison.Ordinal)).ToArray())
        {
            var key = pair.Key[prefix.Length..];
            if (key == "APP_CONNSTRING" && !isSecret)
            {
                throw new InvalidOperationException("The Kubernetes migration connection string must be supplied through a secret reference.");
            }
            destination.Add(key, pair.Value);
            source.Remove(pair.Key);
            init.Env.Add(new EnvVarV1
            {
                Name = key,
                ValueFrom = isSecret
                    ? new EnvVarSourceV1 { SecretKeyRef = new SecretKeySelectorV1 { Name = name, Key = key } }
                    : new EnvVarSourceV1 { ConfigMapKeyRef = new ConfigMapKeySelectorV1 { Name = name, Key = key } }
            });
        }
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

    internal sealed class InitBinding(GrateMigrationResource migration, string environment) : IResourceAnnotation
    {
        internal GrateMigrationResource Migration { get; } = migration;
        internal string Environment { get; } = environment;
        internal string Prefix { get; } = $"GRATE_INIT_{migration.Name.Replace('-', '_').ToUpperInvariant()}_";
        internal string[]? Arguments { get; set; }
    }
}

#pragma warning restore ASPIREPIPELINES001
