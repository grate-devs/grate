// Inspect the native 13.6.5 pipeline, including the final target preparation pass.
#pragma warning disable ASPIREPIPELINES001
using System.Text.Json;
using Aspire.Hosting;
using Aspire.Hosting.Pipelines;
using Grate.Aspire.Example.AzureContainerApps;

var output = Environment.GetEnvironmentVariable("GRATE_ACA_CHECK_OUTPUT")
    ?? throw new InvalidOperationException("GRATE_ACA_CHECK_OUTPUT is required.");
Directory.CreateDirectory(output);
var builder = DistributedApplication.CreateBuilder(new DistributedApplicationOptions
{
    Args = ["AppHost:Operation=publish", $"Pipeline:OutputPath={output}", "Pipeline:Step=publish", "Pipeline:ClearCache=true"],
    DisableDashboard = true
});
builder.Configuration["ConnectionStrings:appdb"] = "Host=example.invalid;Database=appdb;Username=offline;Password=publication-check-only";
var resources = AcaExampleModel.Configure(builder);
PipelineConfigurationContext? finalPipeline = null;
builder.Pipeline.AddPipelineConfiguration(context =>
{
    finalPipeline = context;
    return Task.CompletedTask;
});
await using var app = builder.Build();
await PublicationVerification.VerifyImage(app.Services, builder.ExecutionContext, resources.Migration.Resource, output);
await app.RunAsync();
if (finalPipeline is null)
{
    throw new InvalidOperationException("The native pipeline was not configured.");
}
await File.WriteAllTextAsync(Path.Combine(output, "pipeline-check.json"), JsonSerializer.Serialize(
    finalPipeline.Steps.Select(step => new { step.Name, Resource = step.Resource?.Name, step.DependsOnSteps, step.Tags }),
    new JsonSerializerOptions { WriteIndented = true }));
var target = resources.Api.Resource.GetDeploymentTargetAnnotation()?.DeploymentTarget
    ?? throw new InvalidOperationException("The native ACA publisher did not assign the application target.");
var pushes = finalPipeline.GetSteps(resources.Migration.Resource, WellKnownPipelineTags.PushContainerImage).ToArray();
var builds = finalPipeline.GetSteps(resources.Migration.Resource, WellKnownPipelineTags.BuildCompute).ToArray();
var provisions = finalPipeline.GetSteps(target, WellKnownPipelineTags.ProvisionInfrastructure).ToArray();
PublicationVerification.Require(pushes.Length == 1 && builds.Length == 1 && provisions.Length == 1,
    "The real pipeline must contain one migration build, push and application provisioning step.");
PublicationVerification.Require(provisions[0].DependsOnSteps.Contains(pushes[0].Name),
    "Application provisioning must depend directly on the migration image push.");
PublicationVerification.Require(pushes[0].DependsOnSteps.Contains(builds[0].Name),
    "The migration push must depend on its native image build.");
PublicationVerification.VerifyArtifacts(output);
Console.WriteLine("PASS: native ACA publication, secret references and image push/provision dependency verified.");
#pragma warning restore ASPIREPIPELINES001
