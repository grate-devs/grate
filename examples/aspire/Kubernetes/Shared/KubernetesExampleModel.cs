// The sample explicitly selects the registry for the pinned native Kubernetes publisher.
#pragma warning disable ASPIRECOMPUTE003, ASPIREPROBES001
using Aspire.Hosting;
using Aspire.Hosting.ApplicationModel;
using Aspire.Hosting.Kubernetes.Resources;
using Grate.Aspire.Hosting;
using Grate.Aspire.Kubernetes;

namespace Grate.Aspire.Example.Kubernetes;

internal static class KubernetesExampleModel
{
    internal static KubernetesExampleResources Configure(IDistributedApplicationBuilder builder)
    {
        IResourceBuilder<ContainerRegistryResource>? registry = null;
        if (builder.ExecutionContext.IsPublishMode)
        {
            // Supply the actual registry endpoint/repository through AppHost configuration.
            // The example default is deliberately non-routable and is never pushed by offline checks.
            registry = builder.AddContainerRegistry("registry",
                builder.Configuration["Registry:Endpoint"] ?? "registry.example",
                builder.Configuration["Registry:Repository"] ?? "grate");
            builder.AddKubernetesEnvironment("k8s").WithContainerRegistry(registry);
        }
        var database = builder.AddConnectionString("appdb");
        var migration = database.AddGrateMigration(GrateDatabaseProvider.PostgreSql, waitForDatabase: false)
            .WithScriptsFolder("../db");
        var api = builder.AddProject<Projects.Api>("api")
            .WithEnvironment("DatabaseProvider", "postgresql")
            .WithEnvironment("EXAMPLE_SETTING", "preserved")
            .WithReference(database)
            .WithHttpEndpoint(name: "http")
            .WithExternalHttpEndpoints()
            // WithHttpProbe also registers the local Aspire HTTP health check.
            .WithHttpProbe(ProbeType.Readiness, "/health", endpointName: "http")
            .PublishAsKubernetesService(target =>
            {
                var workload = target.Workload ?? throw new InvalidOperationException("The application workload was not generated.");
                workload.Metadata.Labels["grate-example"] = "preserved";
                workload.PodTemplate.Spec.TerminationGracePeriodSeconds = 17;
                workload.PodTemplate.Spec.ServiceAccountName = "grate-example";
                workload.PodTemplate.Spec.ImagePullSecrets.Add(new LocalObjectReferenceV1 { Name = "registry-pull" });
            });
        if (registry is not null)
        {
            migration.WithContainerRegistry(registry);
            api.WithContainerRegistry(registry);
        }
        api.WithGrateMigrationInitContainer(migration, environment: "PRODUCTION");
        return new KubernetesExampleResources(migration, api);
    }
}

internal sealed record KubernetesExampleResources(
    IResourceBuilder<GrateMigrationResource> Migration,
    IResourceBuilder<ProjectResource> Api);
#pragma warning restore ASPIRECOMPUTE003, ASPIREPROBES001
