// The pinned Aspire pipeline API supplies the native App Service provision step.
#pragma warning disable ASPIREPIPELINES001

using Aspire.Hosting;
using Aspire.Hosting.ApplicationModel;
using Aspire.Hosting.Azure;
using Aspire.Hosting.Azure.AppContainers;
using Aspire.Hosting.Pipelines;
using Azure.Provisioning;
using Azure.Provisioning.AppContainers;
using Grate.Aspire.Hosting;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.DependencyInjection.Extensions;

namespace Grate.Aspire.AppService;

/// <summary>Runs grate migrations before Aspire deploys applications to Azure App Service.</summary>
public static class GrateAppServiceExtensions
{
    internal const string JobIdOutput = "grateJobId";
    internal const string GateTag = "grate-migration-job";
    private static readonly TimeSpan DefaultTimeout = TimeSpan.FromMinutes(30);

    /// <summary>Waits for grate locally and gates App Service deployment on a successful Azure Container Apps job execution.</summary>
    /// <remarks>
    /// Configure the migration's scripts, image and secret connection before adding this binding.
    /// The job is started by native Aspire deploy, not publish, and does not serialize independent deployments.
    /// </remarks>
    public static IResourceBuilder<TApplication> WithGrateMigrationBeforeDeploy<TApplication>(
        this IResourceBuilder<TApplication> application,
        IResourceBuilder<GrateMigrationResource> migration,
        IResourceBuilder<AzureContainerAppEnvironmentResource> jobsEnvironment,
        string environment,
        TimeSpan? timeout = null)
        where TApplication : IComputeResource, IResourceWithWaitSupport
    {
        ArgumentNullException.ThrowIfNull(application);
        ArgumentNullException.ThrowIfNull(migration);
        ArgumentNullException.ThrowIfNull(jobsEnvironment);
        ArgumentException.ThrowIfNullOrWhiteSpace(environment);
        var deadline = timeout ?? DefaultTimeout;
        if (deadline < TimeSpan.FromSeconds(1) || deadline > TimeSpan.FromHours(24))
        {
            throw new ArgumentOutOfRangeException(nameof(timeout), "Choose a migration deadline between one second and 24 hours.");
        }
        if (application.ApplicationBuilder != migration.ApplicationBuilder
            || application.ApplicationBuilder != jobsEnvironment.ApplicationBuilder
            || ReferenceEquals(application.Resource, migration.Resource))
        {
            throw new ArgumentException("The application, migration, and jobs environment must be distinct resources in the same AppHost.");
        }
        if (migration.Resource.UsesSharedDatabaseFile)
        {
            throw new NotSupportedException("SQLite shared host files cannot be published as an App Service migration job.");
        }
        if (application.Resource.HasAnnotationOfType<ConsumerBinding>())
        {
            throw new InvalidOperationException("The application already has a grate deployment gate.");
        }
        var completionWaits = application.Resource.Annotations.OfType<WaitAnnotation>()
            .Where(wait => wait.Resource == migration.Resource && wait.WaitType == WaitType.WaitForCompletion).ToArray();
        if (completionWaits.Any(wait => wait.ExitCode != 0))
        {
            throw new InvalidOperationException("The application expects a nonzero migration exit code; the deployment gate requires success.");
        }

        if (application.ApplicationBuilder.ExecutionContext.IsPublishMode)
        {
            var siteEnvironment = GetSiteEnvironment(application);
            if (application.Resource.IsExcludedFromPublish() || application.Resource.Annotations.OfType<DeploymentTargetAnnotation>().Any())
            {
                throw new InvalidOperationException("The grate deployment gate requires a native App Service deployment target.");
            }
            var job = BindJob(migration, jobsEnvironment, environment, deadline);
            if (application.Resource.GetComputeEnvironment() is null)
            {
                application.WithComputeEnvironment(application.ApplicationBuilder.CreateResourceBuilder(siteEnvironment));
            }
            application.WithPipelineConfiguration(context => ConfigureGate(context, application.Resource, siteEnvironment, job));
        }

        application.WithAnnotation(new ConsumerBinding());
        if (completionWaits.Length == 0)
        {
            application.WaitForCompletion(migration);
        }
        return application;
    }

    private static AzureAppServiceEnvironmentResource GetSiteEnvironment<TApplication>(IResourceBuilder<TApplication> application)
        where TApplication : IResource
    {
        if (application.Resource.GetComputeEnvironment() is { } selected)
        {
            return selected as AzureAppServiceEnvironmentResource
                ?? throw new NotSupportedException("The grate deployment gate requires an Azure App Service environment on the consumer.");
        }
        var environments = application.ApplicationBuilder.Resources.OfType<AzureAppServiceEnvironmentResource>().ToArray();
        return environments.Length == 1 ? environments[0]
            : throw new InvalidOperationException("Declare one App Service environment or explicitly select one on the application before adding a grate deployment gate.");
    }

    private static JobBinding BindJob(IResourceBuilder<GrateMigrationResource> migration,
        IResourceBuilder<AzureContainerAppEnvironmentResource> jobsEnvironment, string environment, TimeSpan timeout)
    {
        var resource = migration.Resource;
        if (resource.GetComputeEnvironment() is { } selected && !ReferenceEquals(selected, jobsEnvironment.Resource))
        {
            throw new InvalidOperationException("The migration is assigned to a different compute environment.");
        }
        if (resource.TryGetLastAnnotation<JobBinding>(out var existing))
        {
            if (ReferenceEquals(existing.JobsEnvironment, jobsEnvironment.Resource)
                && existing.Environment == environment && existing.Timeout == timeout)
            {
                return existing;
            }
            throw new InvalidOperationException("One migration job can be shared only when all consumers use the same jobs environment, grate environment and timeout.");
        }
        if (resource.IsExcludedFromPublish()
            || resource.HasAnnotationOfType<AzureContainerAppCustomizationAnnotation>()
            || resource.HasAnnotationOfType<AzureContainerAppJobCustomizationAnnotation>()
            || resource.HasAnnotationOfType<DeploymentTargetAnnotation>()
            || HasConflictingRegistry(resource, jobsEnvironment.Resource))
        {
            throw new InvalidOperationException("The migration already has incompatible publication, registry or Container Apps configuration.");
        }

        migration.PublishAsGrateMigrationImage();
        migration.WithComputeEnvironment(jobsEnvironment);
        var binding = new JobBinding(resource, jobsEnvironment.Resource, environment, timeout);
        migration.WithAnnotation(binding).WithAnnotation(binding.EnvironmentCallback)
            .PublishAsAzureContainerAppJob(binding.ConfigureJob);
        binding.JobCustomization = resource.Annotations.OfType<AzureContainerAppJobCustomizationAnnotation>().Single();
        binding.ImageBuild = resource.Annotations.OfType<DockerfileBuildAnnotation>().Single();
        migration.ApplicationBuilder.Services.TryAddSingleton<IGrateJobClient, AzureGrateJobClient>();
        migration.WithPipelineStepFactory(_ => new PipelineStep
        {
            Name = $"run-grate-{resource.Name}",
            Description = $"Runs grate migration {resource.Name} before App Service deployment.",
            Tags = [GateTag],
            Action = context => ExecuteGate(context, binding)
        });
        return binding;
    }

    private static bool HasConflictingRegistry(GrateMigrationResource migration, AzureContainerAppEnvironmentResource jobsEnvironment) =>
        migration.TryGetLastAnnotation<ContainerRegistryReferenceAnnotation>(out var registry)
        && !ReferenceEquals(registry.Registry, jobsEnvironment);

    internal static void ConfigureGate(PipelineConfigurationContext context, IResource application,
        AzureAppServiceEnvironmentResource siteEnvironment, JobBinding binding)
    {
        if (!ReferenceEquals(application.GetComputeEnvironment(), siteEnvironment) || application.IsExcludedFromPublish())
        {
            throw new InvalidOperationException("The App Service consumer's publication or compute environment changed after adding the grate gate.");
        }
        binding.ValidateConfiguration();

        // Native compute targets are materialized by BeforeStart. The initial graph
        // legitimately has neither target; the final graph wires the actual roll-out.
        var siteTarget = application.GetDeploymentTargetAnnotation(siteEnvironment)?.DeploymentTarget;
        if (siteTarget is null)
        {
            return;
        }
        if (siteTarget is not AzureAppServiceWebSiteResource site || !ReferenceEquals(site.TargetResource, application))
        {
            throw new InvalidOperationException("The grate deployment gate requires a native App Service website.");
        }
        var job = binding.GetJobTarget();
        var gate = context.GetSteps(binding.Migration, GateTag).SingleOrDefault();
        var siteProvision = context.GetSteps(site, WellKnownPipelineTags.ProvisionInfrastructure).SingleOrDefault();
        var jobProvision = context.GetSteps(job, WellKnownPipelineTags.ProvisionInfrastructure).SingleOrDefault();
        var imagePush = context.GetSteps(binding.Migration, WellKnownPipelineTags.PushContainerImage).SingleOrDefault();
        if (gate is null || siteProvision is null || jobProvision is null || imagePush is null)
        {
            throw new InvalidOperationException("The native deployment pipeline is missing its migration gate, job provision, image push, or App Service provision step.");
        }
        DependsOn(gate, jobProvision);
        DependsOn(gate, imagePush);
        DependsOn(siteProvision, gate);
    }

    private static void DependsOn(PipelineStep step, PipelineStep dependency)
    {
        if (!step.DependsOnSteps.Contains(dependency.Name, StringComparer.Ordinal))
        {
            step.DependsOn(dependency);
        }
    }

    private static Task ExecuteGate(PipelineStepContext context, JobBinding binding)
    {
        binding.ValidateConfiguration();
        var output = new BicepOutputReference(JobIdOutput, binding.GetJobTarget());
        return GrateJobRunner.Run(context.Services.GetRequiredService<IGrateJobClient>(), output.GetValueAsync,
            binding.Timeout, context.Services.GetService<TimeProvider>() ?? TimeProvider.System, context.Logger, context.CancellationToken);
    }

    internal sealed class JobBinding(GrateMigrationResource migration, AzureContainerAppEnvironmentResource jobsEnvironment,
        string environment, TimeSpan timeout) : IResourceAnnotation
    {
        internal GrateMigrationResource Migration { get; } = migration;
        internal AzureContainerAppEnvironmentResource JobsEnvironment { get; } = jobsEnvironment;
        internal string Environment { get; } = environment;
        internal TimeSpan Timeout { get; } = timeout;
        internal AzureContainerAppJobCustomizationAnnotation? JobCustomization { get; set; }
        internal DockerfileBuildAnnotation? ImageBuild { get; set; }
        internal EnvironmentCallbackAnnotation EnvironmentCallback { get; } = new((EnvironmentCallbackContext context) =>
        {
            if (!context.EnvironmentVariables.TryGetValue("APP_CONNSTRING", out var value)
                || !IsWholeSecretReference(value, new HashSet<object>(ReferenceEqualityComparer.Instance)))
            {
                throw new InvalidOperationException("The migration connection string must be one deferred secret reference without a published default. Use AddConnectionString or a secret parameter for the whole connection string.");
            }
            context.EnvironmentVariables["ENVIRONMENT"] = environment;
        });

        internal void ValidateConfiguration()
        {
            if (!ReferenceEquals(Migration.GetComputeEnvironment(), JobsEnvironment) || Migration.IsExcludedFromPublish()
                || HasConflictingRegistry(Migration, JobsEnvironment)
                || Migration.HasAnnotationOfType<AzureContainerAppCustomizationAnnotation>()
                || !Migration.Annotations.OfType<AzureContainerAppJobCustomizationAnnotation>().SequenceEqual([JobCustomization])
                || !Migration.Annotations.OfType<DockerfileBuildAnnotation>().SequenceEqual([ImageBuild])
                || !ReferenceEquals(Migration.Annotations.OfType<EnvironmentCallbackAnnotation>().LastOrDefault(), EnvironmentCallback))
            {
                throw new InvalidOperationException("The migration job's publication, environment, or registry changed after adding the grate gate. Configure the migration before binding it.");
            }
        }

        internal AzureContainerAppResource GetJobTarget()
        {
            var target = Migration.GetDeploymentTargetAnnotation(JobsEnvironment);
            return target is { DeploymentTarget: AzureContainerAppResource job }
                && ReferenceEquals(job.TargetResource, Migration) && ReferenceEquals(target.ContainerRegistry, JobsEnvironment)
                ? job : throw new InvalidOperationException("The grate migration requires a native Container Apps job deployment target.");
        }

        internal void ConfigureJob(AzureResourceInfrastructure infrastructure, ContainerAppJob job)
        {
            ValidateConfiguration();
            var container = job.Template.Containers.Single().Value;
            var connection = container?.Env.SingleOrDefault(item => item.Value?.Name.Value == "APP_CONNSTRING")?.Value;
            if (container is null || string.IsNullOrWhiteSpace(connection?.SecretRef.Value)
                || !job.Configuration.Secrets.Any(secret => secret.Value?.Name.Value == connection.SecretRef.Value))
            {
                throw new InvalidOperationException("The native job must provide the grate connection through a Container Apps secret reference.");
            }
            if (container.Args.Any(argument => argument.Value is null))
            {
                throw new NotSupportedException("Grate deployment job arguments must be literals. Use native secret environment references for credentials.");
            }
            container.Resources = new AppContainerResources { Cpu = 0.5, Memory = "1Gi" };
            job.Configuration.TriggerType = ContainerAppJobTriggerType.Manual;
            job.Configuration.ReplicaTimeout = (int)Math.Ceiling(Timeout.TotalSeconds);
            job.Configuration.ReplicaRetryLimit = 0;
            job.Configuration.ManualTriggerConfig = new JobConfigurationManualTriggerConfig
            {
                Parallelism = 1,
                ReplicaCompletionCount = 1
            };
            infrastructure.Add(new ProvisioningOutput(JobIdOutput, typeof(string)) { Value = job.Id });
        }
    }

    private static bool IsWholeSecretReference(object value, HashSet<object> visited)
    {
        if (!visited.Add(value))
        {
            return false;
        }
        return value switch
        {
            ParameterResource parameter => parameter.Secret && parameter.Default is null,
            IAzureKeyVaultSecretReference => true,
            ConnectionStringReference reference => IsWholeSecretReference(reference.ConnectionStringExpression, visited),
            IResourceWithConnectionString connection => IsWholeSecretReference(connection.ConnectionStringExpression, visited),
            ReferenceExpression { Format: "{0}", ValueProviders.Count: 1 } expression when expression.StringFormats[0] is null
                => IsWholeSecretReference(expression.ValueProviders[0], visited),
            _ => false
        };
    }

    private sealed class ConsumerBinding : IResourceAnnotation;
}

#pragma warning restore ASPIREPIPELINES001
