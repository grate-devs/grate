using Azure.Core;
using Microsoft.Extensions.Logging;

namespace Grate.Aspire.AppService;

internal static class GrateJobRunner
{
    private static readonly ResourceType JobType = new("Microsoft.App/jobs");
    private static readonly ResourceType ExecutionType = new("Microsoft.App/jobs/executions");
    private static readonly TimeSpan PollInterval = TimeSpan.FromSeconds(5);

    internal static async Task Run(IGrateJobClient client, Func<CancellationToken, ValueTask<string?>> getJobId,
        TimeSpan timeout, TimeProvider timeProvider, ILogger logger, CancellationToken cancellationToken)
    {
        using var deadline = new CancellationTokenSource(timeout, timeProvider);
        using var stop = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken, deadline.Token);
        var token = stop.Token;
        try
        {
            token.ThrowIfCancellationRequested();
            var value = await getJobId(token);
            if (!ResourceIdentifier.TryParse(value, out var jobId) || jobId is null || jobId.ResourceType != JobType
                || string.IsNullOrWhiteSpace(jobId.SubscriptionId) || string.IsNullOrWhiteSpace(jobId.ResourceGroupName))
            {
                throw new InvalidOperationException("The provisioned migration job did not return a valid Azure Container Apps job resource ID.");
            }
            token.ThrowIfCancellationRequested();
            var executionId = await client.Start(jobId, token);
            if (executionId.ResourceType != ExecutionType || !jobId.Equals(executionId.Parent))
            {
                throw new InvalidOperationException("Azure returned a migration execution ID that does not belong to the provisioned job.");
            }
            // The generated execution name is a safe correlation identifier. Do not fetch job logs.
            logger.LogInformation("Waiting for grate migration job execution {ExecutionName}.", executionId.Name);
            while (true)
            {
                token.ThrowIfCancellationRequested();
                var status = await client.GetStatus(executionId, token);
                token.ThrowIfCancellationRequested();
                switch (status)
                {
                    case "Succeeded":
                        logger.LogInformation("Grate migration job execution {ExecutionName} succeeded.", executionId.Name);
                        return;
                    case "Pending":
                    case "Running":
                    case "Processing":
                        await Task.Delay(PollInterval, timeProvider, token);
                        break;
                    case "Failed":
                    case "Stopped":
                    case "Degraded":
                        throw new InvalidOperationException($"Grate migration job execution {executionId.Name} ended with status {status}. App Service deployment is blocked.");
                    default:
                        throw new InvalidOperationException($"Grate migration job execution {executionId.Name} returned an unknown status. App Service deployment is blocked.");
                }
            }
        }
        catch (OperationCanceledException) when (deadline.IsCancellationRequested && !cancellationToken.IsCancellationRequested)
        {
            throw new TimeoutException("The grate migration did not complete within the deployment deadline. App Service deployment is blocked; check the job's executions before retrying.");
        }
    }
}
