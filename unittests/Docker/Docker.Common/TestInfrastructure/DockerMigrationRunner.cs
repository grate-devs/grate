using DotNet.Testcontainers.Containers;
using grate.Exceptions;
using Microsoft.Extensions.Logging;

namespace Docker.Common.TestInfrastructure;

internal static class DockerMigrationRunner
{
    internal static async Task Run(IContainer container, ILogger logger, CancellationToken executionToken)
    {
        Exception? failure = null;
        long? exitCode = null;

        try
        {
            try
            {
                await container.StartAsync(executionToken);
                // This waits for the one-shot migration to finish, including an immediate exit.
                exitCode = await container.GetExitCodeAsync(executionToken);
            }
            catch (Exception exception)
            {
                failure = exception;
            }

            if (failure is not null || exitCode != 0)
            {
                var (output, error) = await ReadLogs(container, logger);
                if (failure is null)
                {
                    failure = new InvalidOperationException(
                        $"grate failed with exit code {exitCode}.\nOutput:\n{output}\nError:\n{error}");
                }
                else
                {
                    logger.LogWarning("Docker migration failed. Output:\n{Output}\nError:\n{Error}", output, error);
                }
            }
        }
        finally
        {
            try
            {
                await container.DisposeAsync();
            }
            catch (Exception exception)
            {
                if (failure is null)
                {
                    failure = exception;
                }
                else
                {
                    logger.LogWarning(exception, "Could not clean up the migration container after its failure.");
                }
            }
        }

        if (failure is not null)
        {
            throw new MigrationFailed(failure);
        }
    }

    private static async Task<(string Output, string Error)> ReadLogs(IContainer container, ILogger logger)
    {
        using var diagnosticsTimeout = new CancellationTokenSource(TimeSpan.FromSeconds(5));
        try
        {
            return await container.GetLogsAsync(ct: diagnosticsTimeout.Token);
        }
        catch (Exception exception)
        {
            // Creation may have failed before a Docker container ID was assigned.
            logger.LogWarning(exception, "Could not read migration container logs.");
            return (string.Empty, string.Empty);
        }
    }
}
