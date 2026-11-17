// Inspect the pinned Aspire deployment graph and exercise its scheduler without Azure credentials.
#pragma warning disable ASPIREPIPELINES001
using System.Text.RegularExpressions;
using Aspire.Hosting;
using Aspire.Hosting.ApplicationModel;
using Aspire.Hosting.Azure;
using Aspire.Hosting.Pipelines;
using Grate.Aspire.Example.AzureAppService;
using Microsoft.Extensions.DependencyInjection;

var output = Environment.GetEnvironmentVariable("GRATE_APP_SERVICE_CHECK_OUTPUT")
    ?? throw new InvalidOperationException("GRATE_APP_SERVICE_CHECK_OUTPUT is required.");
Directory.CreateDirectory(output);
var builder = DistributedApplication.CreateBuilder(new DistributedApplicationOptions
{
    Args = ["AppHost:Operation=publish", $"Pipeline:OutputPath={output}", "Pipeline:Step=publish", "Pipeline:ClearCache=true"],
    DisableDashboard = true
});
const string dummyPassword = "publication-check-only";
builder.Configuration["ConnectionStrings:appdb"] = $"Host=example.invalid;Database=appdb;Username=offline;Password={dummyPassword}";
var scripts = Path.GetFullPath(Path.Combine(output, "verification-sql"));
Directory.CreateDirectory(Path.Combine(scripts, "up"));
foreach (var file in Directory.GetFiles(Path.Combine(builder.AppHostDirectory, "../db/up"), "*.sql"))
{
    File.Copy(file, Path.Combine(scripts, "up", Path.GetFileName(file)));
}
File.WriteAllText(Path.Combine(scripts, "up/003_failure.ENV.VERIFICATION_FAILURE.sql"), "THIS IS INVALID SQL;");
var resources = AppServiceExampleModel.Configure(builder, scripts);
PipelineConfigurationContext? final = null;
builder.Pipeline.AddPipelineConfiguration(context =>
{
    final = context;
    return Task.CompletedTask;
});

await using var app = builder.Build();
await using var image = new VerificationImage(output, resources.Migration.Resource, builder.ExecutionContext);
await image.Build(app.Services);
await app.RunAsync();
var graph = final ?? throw new InvalidOperationException("Native pipeline was not configured.");
var website = resources.Api.Resource.GetDeploymentTargetAnnotation()?.DeploymentTarget
    ?? throw new InvalidOperationException("No App Service website was generated.");
var job = resources.Migration.Resource.GetDeploymentTargetAnnotation()?.DeploymentTarget as AzureBicepResource
    ?? throw new InvalidOperationException("No Azure job resource was generated.");
var websiteProvision = graph.GetSteps(website, WellKnownPipelineTags.ProvisionInfrastructure).Single();
var jobProvision = graph.GetSteps(job, WellKnownPipelineTags.ProvisionInfrastructure).Single();
var jobPush = graph.GetSteps(resources.Migration.Resource, WellKnownPipelineTags.PushContainerImage).Single();
var webPush = graph.GetSteps(resources.Api.Resource, WellKnownPipelineTags.PushContainerImage).Single();
var gate = graph.GetSteps("grate-migration-job").Single();
Require(websiteProvision.DependsOnSteps.Contains(gate.Name) && websiteProvision.DependsOnSteps.Contains(webPush.Name),
    "The actual website provision step must wait for the migration and the application image push.");
Require(gate.DependsOnSteps.Contains(jobProvision.Name) && gate.DependsOnSteps.Contains(jobPush.Name),
    "The migration must wait for its job definition and image.");
Require(jobProvision.DependsOnSteps.Contains(jobPush.Name),
    "Azure must receive the packaged image before provisioning the job.");
var steps = graph.Steps.ToDictionary(step => step.Name, StringComparer.Ordinal);
var visiting = new HashSet<string>(StringComparer.Ordinal);
var confirmed = new HashSet<string>(StringComparer.Ordinal);
Visit(WellKnownPipelineSteps.Deploy);
Require(confirmed.Contains(websiteProvision.Name) && confirmed.Contains(gate.Name),
    "The native deploy command must reach both the website provisioning and migration steps.");
var jobBicep = File.ReadAllText(Directory.GetFiles(output, "appdb-grate.bicep", SearchOption.AllDirectories).Single());
var siteBicep = File.ReadAllText(Directory.GetFiles(output, "api.bicep", SearchOption.AllDirectories).Single());
var jobDeclaration = Regex.Match(jobBicep, @"^resource (\w+) 'Microsoft\.App/jobs@", RegexOptions.Multiline);
Require(jobDeclaration.Success
    && jobBicep.Contains("triggerType: 'Manual'", StringComparison.Ordinal)
    && jobBicep.Contains("parallelism: 1", StringComparison.Ordinal)
    && jobBicep.Contains("replicaCompletionCount: 1", StringComparison.Ordinal)
    && jobBicep.Contains("replicaRetryLimit: 0", StringComparison.Ordinal)
    && jobBicep.Contains("value: 'PRODUCTION'", StringComparison.Ordinal)
    && jobBicep.Contains($"output grateJobId string = {jobDeclaration.Groups[1].Value}.id", StringComparison.Ordinal)
    && jobBicep.Contains("exec /app/grate", StringComparison.Ordinal)
    && Regex.IsMatch(jobBicep, @"name: 'APP_CONNSTRING'\s+secretRef:")
    && Regex.IsMatch(jobBicep, @"@secure\(\)\s+param appdb_connectionstring string")
    && !jobBicep.Contains(dummyPassword, StringComparison.Ordinal),
    "Native Bicep must emit a finite manual job with the selected environment and a secure connection reference.");
Require(siteBicep.Contains("'Microsoft.Web/sites@", StringComparison.Ordinal)
    && !siteBicep.Contains("APP_CONNSTRING", StringComparison.Ordinal)
    && !siteBicep.Contains(dummyPassword, StringComparison.Ordinal),
    "The website must not receive the migration job's settings or literal credentials.");
Console.WriteLine("PASS: native App Service Bicep and website provisioning dependency.");

await GateVerification.Verify(output, job, image, [jobPush, jobProvision, gate, webPush, websiteProvision], gate, websiteProvision);

void Visit(string name)
{
    if (confirmed.Contains(name))
    {
        return;
    }
    Require(visiting.Add(name), $"Native deployment graph has a dependency cycle at '{name}'.");
    foreach (var dependency in steps[name].DependsOnSteps)
    {
        Visit(dependency);
    }
    visiting.Remove(name);
    confirmed.Add(name);
}

static void Require(bool condition, string message)
{
    if (!condition)
    {
        throw new InvalidOperationException(message);
    }
}
