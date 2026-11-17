// Replay the native deployment edges and the production gate action in Aspire's actual scheduler.
#pragma warning disable ASPIREPIPELINES001
using Aspire.Hosting;
using Aspire.Hosting.ApplicationModel;
using Aspire.Hosting.Azure;
using Aspire.Hosting.Pipelines;
using Azure.Core;
using Grate.Aspire.AppService;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Logging.Abstractions;

namespace Grate.Aspire.Example.AzureAppService;

internal static class GateVerification
{
    private static readonly ResourceIdentifier JobId = new(
        "/subscriptions/00000000-0000-0000-0000-000000000001/resourceGroups/verification/providers/Microsoft.App/jobs/appdb-grate");

    internal static async Task Verify(string output, AzureBicepResource job, VerificationImage image,
        PipelineStep[] selected, PipelineStep gate, PipelineStep websiteProvision)
    {
        await RunCase(output, job, image, selected, gate, websiteProvision, successfulSql: true);
        await RunCase(output, job, image, selected, gate, websiteProvision, successfulSql: false);
    }

    private static async Task RunCase(string output, AzureBicepResource job, VerificationImage image, PipelineStep[] selected,
        PipelineStep gate, PipelineStep websiteProvision, bool successfulSql)
    {
        var client = new LocalJobClient(image, successfulSql);
        job.Outputs.Remove(GrateAppServiceExtensions.JobIdOutput);
        job.ProvisioningTaskCompletionSource = new(TaskCreationOptions.RunContinuationsAsynchronously);
        var builder = DistributedApplication.CreateBuilder(new DistributedApplicationOptions
        {
            Args = [$"Pipeline:Step={websiteProvision.Name}", $"Pipeline:OutputPath={output}", "Pipeline:ClearCache=true"],
            ProjectDirectory = output,
            DisableDashboard = true
        });
        builder.Services.AddSingleton<IGrateJobClient>(client);
        var names = selected.Select(step => step.Name).ToHashSet(StringComparer.Ordinal);
        var websiteChanges = 0;
        foreach (var step in selected)
        {
            builder.Pipeline.AddStep(new PipelineStep
            {
                Name = step.Name,
                DependsOnSteps = step.DependsOnSteps.Where(names.Contains).ToList(),
                Action = step == gate ? gate.Action :
                    step == websiteProvision ? VerifyWebsiteProvision :
                    step.Resource == job ? CompleteJobProvision : _ => Task.CompletedTask
            });
        }

        await using var app = builder.Build();
        // Only the copied steps are present. Azure provisioning and image side effects are markers,
        // while run-grate retains its production action and the scheduler retains the native ordering.
        using var deadline = new CancellationTokenSource(TimeSpan.FromMinutes(4));
        var context = new PipelineContext(new DistributedApplicationModel(Array.Empty<IResource>()), builder.ExecutionContext,
            app.Services, NullLogger.Instance, deadline.Token);
        Exception? failure = null;
        try
        {
            await builder.Pipeline.ExecuteAsync(context);
        }
        catch (Exception error)
        {
            failure = error;
        }
        if (client.Starts != 1 || client.StatusReads != 1 || (successfulSql
            ? failure is not null || websiteChanges != 1
            : failure is null || websiteChanges != 0))
        {
            throw new InvalidOperationException("Aspire must provision the website exactly once on success and leave it untouched after SQL failure.", failure);
        }
        Console.WriteLine(successfulSql
            ? "PASS: successful grate SQL allowed Aspire website provisioning."
            : "PASS: invalid SQL failed the job and Aspire skipped website provisioning.");

        Task CompleteJobProvision(PipelineStepContext _)
        {
            // Stand in for successful Azure provisioning with a fixture resource ID.
            job.Outputs[GrateAppServiceExtensions.JobIdOutput] = JobId.ToString();
            job.ProvisioningTaskCompletionSource!.SetResult();
            return Task.CompletedTask;
        }

        Task VerifyWebsiteProvision(PipelineStepContext _)
        {
            if (!client.StatusRead)
            {
                throw new InvalidOperationException("The website provision step ran before the job returned a terminal status.");
            }
            websiteChanges++;
            return Task.CompletedTask;
        }
    }

    private sealed class LocalJobClient(VerificationImage image, bool successfulSql) : IGrateJobClient
    {
        private static readonly ResourceIdentifier ExecutionId = new($"{JobId}/executions/verification-run");
        private string? _status;
        internal int Starts { get; private set; }
        internal int StatusReads { get; private set; }
        internal bool StatusRead => StatusReads > 0;

        public async Task<ResourceIdentifier> Start(ResourceIdentifier jobId, CancellationToken cancellationToken)
        {
            if (jobId != JobId || ++Starts != 1)
            {
                throw new InvalidOperationException("The gate must start the provisioned job exactly once.");
            }
            _status = await image.RunSql(successfulSql, cancellationToken) ? "Succeeded" : "Failed";
            return ExecutionId;
        }

        public Task<string?> GetStatus(ResourceIdentifier executionId, CancellationToken cancellationToken)
        {
            cancellationToken.ThrowIfCancellationRequested();
            if (executionId != ExecutionId || _status is null)
            {
                throw new InvalidOperationException("The gate must follow only the execution returned by Start.");
            }
            StatusReads++;
            return Task.FromResult<string?>(_status);
        }
    }
}
