// Inspect the pinned native pipeline after its final deployment-target preparation pass.
#pragma warning disable ASPIREPIPELINES001
using System.Text.Json;
using Aspire.Hosting;
using Aspire.Hosting.ApplicationModel;
using Aspire.Hosting.Pipelines;
using Grate.Aspire.Example.Kubernetes;

var output = Environment.GetEnvironmentVariable("GRATE_KUBE_CHECK_OUTPUT")
    ?? throw new InvalidOperationException("GRATE_KUBE_CHECK_OUTPUT is required.");
Directory.CreateDirectory(output);
var builder = DistributedApplication.CreateBuilder(new DistributedApplicationOptions
{
    Args = ["AppHost:Operation=publish", $"Pipeline:OutputPath={output}", "Pipeline:Step=publish", "Pipeline:ClearCache=true"],
    DisableDashboard = true
});
builder.Configuration["ConnectionStrings:appdb"] = KubernetesPublicationVerification.DummyConnection;
var resources = KubernetesExampleModel.Configure(builder);
PipelineConfigurationContext? finalPipeline = null;
builder.Pipeline.AddPipelineConfiguration(context =>
{
    finalPipeline = context;
    return Task.CompletedTask;
});
await using var app = builder.Build();
if (Environment.GetEnvironmentVariable("GRATE_KUBE_BUILD_IMAGE") is { Length: > 0 } image)
{
    // The caller owns this tag and its cleanup. Keep the AppHost-managed SQL context alive
    // until the build completes; no credentials enter that context or Docker command.
    var build = resources.Migration.Resource.Annotations.OfType<DockerfileBuildAnnotation>().Single();
    await build.EmitDockerfileArtifactsAsync(new DockerfileFactoryContext
    {
        Resource = resources.Migration.Resource,
        Services = app.Services
    });
    await KubernetesPublicationVerification.Run("docker",
        ["build", "--tag", image, "--file", build.DockerfilePath, build.ContextPath], output, "image-build", TimeSpan.FromMinutes(4));
    Console.WriteLine("PASS: caller-owned migration image built from the native packaged SQL context.");
}
await app.RunAsync();
var pipeline = finalPipeline ?? throw new InvalidOperationException("The native pipeline was not configured.");
await File.WriteAllTextAsync(Path.Combine(output, "pipeline-check.json"), JsonSerializer.Serialize(
    pipeline.Steps.Select(step => new { step.Name, Resource = step.Resource?.Name, step.DependsOnSteps, step.Tags }),
    new JsonSerializerOptions { WriteIndented = true }));
var pushes = pipeline.GetSteps(resources.Migration.Resource, WellKnownPipelineTags.PushContainerImage).ToArray();
var builds = pipeline.GetSteps(resources.Migration.Resource, WellKnownPipelineTags.BuildCompute).ToArray();
var helmDeploy = pipeline.Steps.Single(step => step.Name == "helm-deploy-k8s" && step.Tags.Contains("helm-deploy"));
KubernetesPublicationVerification.Require(pushes.Length == 1 && builds.Length == 1,
    "The native pipeline must contain one migration image build and push.");
KubernetesPublicationVerification.Require(DependsOn(helmDeploy.Name, pushes[0].Name),
    "The actual native Helm deploy step must wait for the migration image push.");
KubernetesPublicationVerification.Require(DependsOn(pushes[0].Name, builds[0].Name),
    "The migration push must wait for its native image build.");
await KubernetesPublicationVerification.VerifyArtifacts(output, resources);
Console.WriteLine("PASS: native Kubernetes publication, Helm rendering, init secrets and image push/deploy ordering verified.");

bool DependsOn(string stepName, string dependency)
{
    var steps = pipeline.Steps.ToDictionary(step => step.Name, StringComparer.Ordinal);
    var visited = new HashSet<string>(StringComparer.Ordinal);
    return Visit(stepName);

    bool Visit(string current)
    {
        if (!visited.Add(current) || !steps.TryGetValue(current, out var step))
        {
            return false;
        }
        return step.DependsOnSteps.Contains(dependency) || step.DependsOnSteps.Any(Visit);
    }
}
#pragma warning restore ASPIREPIPELINES001
