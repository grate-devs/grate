using System.Text.Json;
using Aspire.Hosting.Azure;
using Azure;
using Azure.Core;
using Azure.ResourceManager;
using Azure.ResourceManager.AppContainers;

namespace Grate.Aspire.AppService;

internal interface IGrateJobClient
{
    Task<ResourceIdentifier> Start(ResourceIdentifier jobId, CancellationToken cancellationToken);
    Task<string?> GetStatus(ResourceIdentifier executionId, CancellationToken cancellationToken);
}

internal sealed class AzureGrateJobClient : IGrateJobClient
{
    private readonly ArmClient _arm;

    public AzureGrateJobClient(ITokenCredentialProvider credentials) : this(credentials.TokenCredential, new ArmClientOptions()) { }

    internal AzureGrateJobClient(TokenCredential credential, ArmClientOptions options)
    {
        // Match Aspire's default ARM cloud and reuse its configured credential. Starting
        // the job isn't idempotent, so a lost response must never cause a second POST.
        options.Retry.MaxRetries = 0;
        options.Diagnostics.IsLoggingContentEnabled = false;
        _arm = new ArmClient(credential, defaultSubscriptionId: null, options);
    }

    public async Task<ResourceIdentifier> Start(ResourceIdentifier jobId, CancellationToken cancellationToken)
    {
        try
        {
            var job = _arm.GetContainerAppJobResource(jobId);
            // Completed here means Azure has finished processing Start, not that SQL has run.
            // The SDK follows the ARM Location polling contract and returns this start's ID.
            var operation = await job.StartAsync(WaitUntil.Completed, cancellationToken: cancellationToken);
            if (!operation.HasValue || !ResourceIdentifier.TryParse(operation.Value.Id, out var executionId) || executionId is null)
            {
                throw new InvalidOperationException("Azure did not return a valid migration execution ID. Check the job's executions before retrying deployment.");
            }
            return executionId;
        }
        catch (RequestFailedException exception)
        {
            // ARM errors can contain the job template. Keep response bodies out of deployment logs.
            throw new InvalidOperationException($"Azure rejected or could not confirm the migration job start (HTTP {exception.Status}). No start was retried; check the job's executions before retrying deployment.");
        }
        catch (JsonException)
        {
            throw new InvalidOperationException("Azure did not return a readable migration job start result. Check the job's executions before retrying deployment.");
        }
    }

    public async Task<string?> GetStatus(ResourceIdentifier executionId, CancellationToken cancellationToken)
    {
        try
        {
            var response = await _arm.GetContainerAppJobExecutionResource(executionId).GetAsync(cancellationToken);
            if (!executionId.Equals(response.Value.Data.Id))
            {
                throw new InvalidOperationException("Azure returned a different migration execution than requested.");
            }
            return response.Value.Data.Status?.ToString();
        }
        catch (RequestFailedException exception) when (exception.Status is 404 or 408 or 429 or >= 500 and <= 599)
        {
            // The execution can take time to appear. Only this read may be retried,
            // at the ordinary poll interval and within the single deployment deadline.
            return "Pending";
        }
        catch (RequestFailedException exception)
        {
            throw new InvalidOperationException($"Azure could not read the migration execution status (HTTP {exception.Status}).");
        }
        catch (JsonException)
        {
            throw new InvalidOperationException("Azure did not return a readable migration execution status.");
        }
    }
}
