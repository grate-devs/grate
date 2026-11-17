using System.Diagnostics;
using Aspire.Hosting;
using Aspire.Hosting.ApplicationModel;
using Grate.Aspire.Hosting;
using Microsoft.Data.Sqlite;

namespace Grate.Aspire.Example.AzureAppService;

internal sealed class VerificationImage(string output, GrateMigrationResource migration,
    DistributedApplicationExecutionContext execution) : IAsyncDisposable
{
    private readonly string _tag = $"grate-appservice-check:{Guid.NewGuid():N}";
    private readonly string _container = $"grate-appservice-check-{Guid.NewGuid():N}";
    private string[]? _arguments;
    private bool _built;

    internal async Task Build(IServiceProvider services)
    {
        var build = migration.Annotations.OfType<DockerfileBuildAnnotation>().Single();
        await build.EmitDockerfileArtifactsAsync(new DockerfileFactoryContext { Resource = migration, Services = services });
        await Docker(["build", "--tag", _tag, "--file", build.DockerfilePath, build.ContextPath], "build");
        _built = true;
        var arguments = new List<object>();
        var context = new CommandLineArgsCallbackContext(arguments, migration) { ExecutionContext = execution };
        foreach (var callback in migration.Annotations.OfType<CommandLineArgsCallbackAnnotation>())
        {
            await callback.Callback(context);
        }
        _arguments = arguments.Cast<string>().ToArray();
    }

    internal async Task<bool> RunSql(bool successfulSql, CancellationToken cancellationToken)
    {
        // This portable SQL fixture needs only a disposable local database. The native
        // publication checked above uses PostgreSQL. Docker supplies the process exit
        // code that the simulated job reports to the real pipeline gate.
        var name = successfulSql ? "successful-sql" : "invalid-sql";
        var data = Directory.CreateDirectory(Path.Combine(output, name)).FullName;
        var environment = successfulSql ? "PRODUCTION" : "VERIFICATION_FAILURE";
        List<string> arguments =
        [
            "run", "--rm", "--network", "none", "--name", _container,
            "--mount", $"type=bind,source={data},target=/verification",
            "--env", "APP_CONNSTRING=Data Source=/verification/demo.db",
            "--env", "DATABASE_TYPE=sqlite",
            "--env", "CREATE_DATABASE=false",
            "--env", $"ENVIRONMENT={environment}",
            "--env", "GRATE_OUTPUT_PATH=/tmp/grate-output",
            "--env", "DOTNET_BUNDLE_EXTRACT_BASE_DIR=/tmp/dotnet-bundle",
            "--entrypoint", migration.Entrypoint ?? "/bin/sh",
            _tag
        ];
        arguments.AddRange(_arguments ?? throw new InvalidOperationException("The migration image was not built."));
        var exitCode = await Docker(arguments, name, cancellationToken, allowFailure: !successfulSql);
        await using var connection = new SqliteConnection(
            $"Data Source={Path.Combine(data, "demo.db")};Mode=ReadOnly;Pooling=False");
        await connection.OpenAsync(cancellationToken);
        await using var query = connection.CreateCommand();
        if (successfulSql)
        {
            query.CommandText = "SELECT message FROM aspire_demo WHERE id = 2";
            if ((string?)await query.ExecuteScalarAsync(cancellationToken) != "PRODUCTION")
            {
                throw new InvalidOperationException("The packaged production SQL did not run.");
            }
        }
        else
        {
            query.CommandText = "SELECT COUNT(*) FROM grate_ScriptsRunErrors WHERE script_name LIKE '%003_failure%'";
            if (exitCode == 0 || (long?)await query.ExecuteScalarAsync(cancellationToken) != 1)
            {
                throw new InvalidOperationException("The failure case must exit nonzero and record the deliberate SQL error.");
            }
        }
        return exitCode == 0;
    }

    public async ValueTask DisposeAsync()
    {
        await Docker(["rm", "--force", _container], "container-cleanup", allowFailure: true);
        if (_built)
        {
            await Docker(["image", "rm", "--force", _tag], "image-cleanup");
        }
    }

    private async Task<int> Docker(IEnumerable<string> arguments, string log,
        CancellationToken cancellationToken = default, bool allowFailure = false)
    {
        var start = new ProcessStartInfo("docker") { RedirectStandardOutput = true, RedirectStandardError = true, UseShellExecute = false };
        foreach (var argument in arguments)
        {
            start.ArgumentList.Add(argument);
        }
        using var process = Process.Start(start) ?? throw new InvalidOperationException("Could not start Docker.");
        var stdout = process.StandardOutput.ReadToEndAsync();
        var stderr = process.StandardError.ReadToEndAsync();
        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        timeout.CancelAfter(TimeSpan.FromMinutes(4));
        try
        {
            await process.WaitForExitAsync(timeout.Token);
        }
        catch (OperationCanceledException)
        {
            if (!process.HasExited)
            {
                process.Kill(entireProcessTree: true);
            }
            await process.WaitForExitAsync(CancellationToken.None);
            throw;
        }
        await File.WriteAllTextAsync(Path.Combine(output, $"{log}.log"), await stdout + await stderr, CancellationToken.None);
        if (process.ExitCode != 0 && !allowFailure)
        {
            throw new InvalidOperationException($"Docker {log} failed with exit code {process.ExitCode}. See local verification artifacts.");
        }
        return process.ExitCode;
    }
}
