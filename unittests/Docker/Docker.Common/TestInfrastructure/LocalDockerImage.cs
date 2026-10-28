using System.Collections.Concurrent;
using System.Diagnostics;
using System.Reflection;
using Microsoft.Extensions.Logging;

namespace Docker.Common.TestInfrastructure;

internal static class LocalDockerImage
{
    private static readonly ConcurrentDictionary<string, Lazy<Task>> Builds = new();

    internal static Task Ensure(string image, ILogger logger, CancellationToken cancellationToken)
    {
        if (string.Equals(Environment.GetEnvironmentVariable("GrateBuildLocalDockerImage"), "false", StringComparison.OrdinalIgnoreCase))
        {
            return Task.CompletedTask;
        }

        var planFile = Path.Combine(AppContext.BaseDirectory,
            Assembly.GetEntryAssembly()?.GetName().Name + ".docker-build");
        return Ensure(image, planFile, logger, cancellationToken);
    }

    internal static Task Ensure(string image, string planFile, ILogger logger, CancellationToken cancellationToken)
    {
        if (image != "grate-local:tests" || !File.Exists(planFile)) return Task.CompletedTask;

        var plan = File.ReadAllLines(planFile);
        if (plan.Length != 3)
            throw new InvalidOperationException($"Invalid local Docker image build plan: {planFile}");

        // All Docker projects/TFMs in one MSBuild invocation receive the same plan.
        // Lazy shares work within this process; the file lock shares it across modules.
        return Builds.GetOrAdd(plan[2], _ => new Lazy<Task>(() => Build(plan, logger, cancellationToken))).Value;
    }

    private static async Task Build(string[] plan, ILogger logger, CancellationToken cancellationToken)
    {
        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        timeout.CancelAfter(TimeSpan.FromMinutes(10));
        var token = timeout.Token;
        await using var imageLock = await Lock(plan[2] + ".lock", token);
        if (File.Exists(plan[2] + ".built")) return;
        var failureFile = plan[2] + ".failed";
        if (File.Exists(failureFile))
            throw new InvalidOperationException(await File.ReadAllTextAsync(failureFile, token));

        try
        {
            await RunBuild(plan, logger, cancellationToken, token);
            await File.WriteAllTextAsync(plan[2] + ".built", "grate-local:tests", token);
        }
        catch (Exception exception) when (!cancellationToken.IsCancellationRequested)
        {
            // A failed build must not be retried by every remaining test module.
            // The next normal .NET build creates a fresh plan and permits a retry.
            try
            {
                await File.WriteAllTextAsync(failureFile, exception.ToString(), CancellationToken.None);
            }
            catch (Exception statusFailure) when (statusFailure is IOException or UnauthorizedAccessException)
            {
                logger.LogWarning(statusFailure, "Could not share the local Docker image build failure.");
            }
            throw;
        }
    }

    private static async Task RunBuild(string[] plan, ILogger logger, CancellationToken cancellationToken,
        CancellationToken timeoutToken)
    {
        logger.LogInformation("Building local Docker test image grate-local:tests.");
        var start = new ProcessStartInfo(plan[1])
        {
            WorkingDirectory = plan[0],
            UseShellExecute = false,
            RedirectStandardOutput = true,
            RedirectStandardError = true
        };
        foreach (var argument in new[] { "build", "--file", "installers/docker/Dockerfile", "--tag", "grate-local:tests", "." })
            start.ArgumentList.Add(argument);
        if (OperatingSystem.IsWindows() &&
            (Path.GetExtension(plan[1]).Equals(".cmd", StringComparison.OrdinalIgnoreCase) ||
             Path.GetExtension(plan[1]).Equals(".bat", StringComparison.OrdinalIgnoreCase)))
        {
            start.FileName = Environment.GetEnvironmentVariable("ComSpec") ?? "cmd.exe";
            start.ArgumentList.Clear();
            start.Arguments = $"/d /s /c \"\"{plan[1]}\" build --file installers/docker/Dockerfile --tag grate-local:tests .\"";
        }

        using var process = Process.Start(start) ?? throw new InvalidOperationException("Could not start Docker image build.");
        var stdout = process.StandardOutput.ReadToEndAsync();
        var stderr = process.StandardError.ReadToEndAsync();
        try
        {
            await process.WaitForExitAsync(timeoutToken);
        }
        catch (OperationCanceledException)
        {
            if (!process.HasExited) process.Kill(entireProcessTree: true);
            await process.WaitForExitAsync(CancellationToken.None);
            var output = await stdout + await stderr;
            cancellationToken.ThrowIfCancellationRequested();
            throw new TimeoutException("Local Docker image build timed out after 10 minutes.\n" + output);
        }

        var buildOutput = await stdout + await stderr;
        if (process.ExitCode != 0)
            throw new InvalidOperationException($"Local Docker image build failed with exit code {process.ExitCode}.\n{buildOutput}");
    }

    private static async Task<FileStream> Lock(string path, CancellationToken cancellationToken)
    {
        while (true)
        {
            cancellationToken.ThrowIfCancellationRequested();
            try
            {
                return new FileStream(path, FileMode.OpenOrCreate, FileAccess.ReadWrite, FileShare.None);
            }
            catch (IOException) when (File.Exists(path))
            {
                await Task.Delay(TimeSpan.FromMilliseconds(100), cancellationToken);
            }
        }
    }
}
