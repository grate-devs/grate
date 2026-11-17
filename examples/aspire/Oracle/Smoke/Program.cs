using System.Diagnostics;
using System.Globalization;
using System.Security.Cryptography;
using Aspire.Hosting;
using Aspire.Hosting.ApplicationModel;
using Grate.Aspire.Hosting;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Logging;
using Oracle.ManagedDataAccess.Client;

var selected = args.Length == 0 ? "all" : args[0];
string[] scenarios = ["success", "retained", "sql-failure", "credentials-failure"];
if (selected != "all" && !scenarios.Contains(selected, StringComparer.Ordinal))
{
    throw new ArgumentException("Choose all, success, retained, sql-failure or credentials-failure.");
}
foreach (var scenario in scenarios.Where(value => selected == "all" || value == selected))
{
    await OracleSmoke.Run(scenario);
    Console.WriteLine($"PASS: oracle {scenario}");
}

internal static class OracleSmoke
{
    public static async Task Run(string scenario)
    {
        using var timeout = new CancellationTokenSource(TimeSpan.FromMinutes(10));
        var identity = Guid.NewGuid().ToString("N");
        var directory = Directory.CreateTempSubdirectory($"grate aspire oracle {identity} ").FullName;
        var scripts = Path.Combine(directory, "sql scripts");
        Directory.CreateDirectory(Path.Combine(scripts, "up"));
        var volume = $"grate-aspire-oracle-smoke-{identity}";
        var sql = scenario == "sql-failure" ? "THIS IS NOT VALID SQL;"
            : await File.ReadAllTextAsync(Path.Combine(AppContext.BaseDirectory, "fixtures", "001_create_demo.sql"), timeout.Token);
        await File.WriteAllTextAsync(Path.Combine(scripts, "up", "001_create_demo.sql"), sql, timeout.Token);
        var password = $"Grate1{RandomNumberGenerator.GetHexString(24)}";
        try
        {
            var first = await RunApplication(scenario, scripts, volume, password, timeout.Token);
            if (scenario == "retained")
            {
                var second = await RunApplication("success", scripts, volume, password, timeout.Token);
                Require(first == second, "Retained restart changed the one-time history identity/hash.");
            }
        }
        finally
        {
            OracleConnection.ClearAllPools();
            using var cleanup = new CancellationTokenSource(TimeSpan.FromSeconds(45));
            await Docker(["volume", "rm", "--force", volume], cleanup.Token);
            Directory.Delete(directory, recursive: true);
        }
    }

    private static async Task<string?> RunApplication(
        string scenario, string scripts, string volume, string password, CancellationToken cancellationToken)
    {
        var identity = Guid.NewGuid().ToString("N");
        var migrationContainer = $"grate-aspire-oracle-migration-{identity}";
        var serverContainer = $"grate-aspire-oracle-server-{identity}";
        var builder = DistributedApplication.CreateBuilder(new DistributedApplicationOptions { Args = [], DisableDashboard = true });
        builder.Services.AddLogging(logging =>
        {
            logging.ClearProviders();
            logging.AddConsole();
            logging.SetMinimumLevel(LogLevel.Critical);
        });
        var secret = builder.AddParameter("password", password, secret: true);
        var server = builder.AddOracle("oracle", secret)
            .WithImage("gvenzl/oracle-free", "23.26.3-faststart")
            .WithImageRegistry("docker.io")
            .WithEnvironment("ORACLE_PASSWORD", secret)
            .WithContainerName(serverContainer)
            .WithDataVolume(volume);
        var database = server.AddDatabase("appdb", "FREEPDB1");
        var migration = database.AddGrateMigration().WithScriptsFolder(scripts, containerPath: "/sql scripts")
            .WithContainerName(migrationContainer);
        if (scenario == "credentials-failure")
        {
            migration.WithEnvironment("APP_CONNSTRING", ReferenceExpression.Create(
                $"User Id=system;Password=deliberately-wrong;Data Source={server.Resource.PrimaryEndpoint.Property(EndpointProperty.HostAndPort)}/FREEPDB1"));
        }
        var api = builder.AddProject<Projects.Api>("api")
            .WithReference(database)
            .WithHttpEndpoint(name: "http")
            .WithHttpHealthCheck("/health")
            .WaitForCompletion(migration);
        await using var app = builder.Build();
        var notifications = app.Services.GetRequiredService<ResourceNotificationService>();
        using var startup = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        Task? starting = null;
        try
        {
            starting = app.StartAsync(startup.Token);
            await starting;
            var completion = await notifications.WaitForResourceAsync(migration.Resource.Name,
                resource => resource.Snapshot.ExitCode.HasValue, cancellationToken);
            await CheckLogs(migrationContainer, [password, "deliberately-wrong"], cancellationToken);
            if (scenario is "sql-failure" or "credentials-failure")
            {
                Require(completion.Snapshot.ExitCode != 0, "Deliberately failing migration returned success.");
                await notifications.WaitForResourceAsync("api", KnownResourceStates.FailedToStart, cancellationToken);
                if (scenario == "sql-failure")
                {
                    await using var failed = await OpenDatabase(database, cancellationToken);
                    await using var errors = failed.CreateCommand();
                    errors.CommandText = "SELECT COUNT(*) FROM grate_ScriptsRunErrors";
                    Require(Convert.ToInt64(await errors.ExecuteScalarAsync(cancellationToken), CultureInfo.InvariantCulture) > 0,
                        "SQL failure left no error history.");
                    await using var effects = failed.CreateCommand();
                    effects.CommandText = "SELECT COUNT(*) FROM user_tables WHERE table_name = 'ASPIRE_DEMO'";
                    Require(Convert.ToInt64(await effects.ExecuteScalarAsync(cancellationToken), CultureInfo.InvariantCulture) == 0,
                        "SQL failure unexpectedly created the application table.");
                }
                return null;
            }
            Require(completion.Snapshot.ExitCode == 0, "Migration failed.");
            await notifications.WaitForResourceHealthyAsync("api", cancellationToken);
            using var client = new HttpClient { BaseAddress = new Uri(api.GetEndpoint("http").Url) };
            Require(await client.GetStringAsync("/", cancellationToken) == "Hello from grate", "API did not read the migrated seed row.");
            await using var connection = await OpenDatabase(database, cancellationToken);
            await using var count = connection.CreateCommand();
            count.CommandText = "SELECT COUNT(*) FROM aspire_demo";
            Require(Convert.ToInt64(await count.ExecuteScalarAsync(cancellationToken), CultureInfo.InvariantCulture) == 1,
                "Unexpected seed row count.");
            await using var history = connection.CreateCommand();
            history.CommandText = "SELECT id, text_hash FROM grate_ScriptsRun WHERE script_name = '001_create_demo.sql' AND one_time_script = '1'";
            await using var reader = await history.ExecuteReaderAsync(cancellationToken);
            Require(await reader.ReadAsync(cancellationToken), "One-time history missing.");
            var fingerprint = $"{reader.GetValue(0)}:{reader.GetString(1)}";
            Require(!await reader.ReadAsync(cancellationToken), "Duplicate one-time history row.");
            return fingerprint;
        }
        finally
        {
            using var shutdown = new CancellationTokenSource(TimeSpan.FromSeconds(60));
            startup.Cancel();
            try
            {
                await app.StopAsync(shutdown.Token);
                if (starting is not null)
                {
                    try
                    {
                        await starting;
                    }
                    catch (OperationCanceledException) when (startup.IsCancellationRequested)
                    {
                        // Observe expected startup cancellation during cleanup.
                    }
                }
            }
            finally
            {
                // These exact unique names are owned by this invocation, including failed startup.
                using var cleanup = new CancellationTokenSource(TimeSpan.FromSeconds(45));
                await RemoveContainer(migrationContainer, cleanup.Token);
                await RemoveContainer(serverContainer, cleanup.Token);
            }
        }
    }

    private static async Task<OracleConnection> OpenDatabase(
        IResourceBuilder<OracleDatabaseResource> database, CancellationToken cancellationToken)
    {
        var value = await database.Resource.ConnectionStringExpression.GetValueAsync(cancellationToken);
        var connection = new OracleConnection(value);
        try
        {
            await connection.OpenAsync(cancellationToken);
            return connection;
        }
        catch
        {
            await connection.DisposeAsync();
            throw;
        }
    }

    private static async Task RemoveContainer(string container, CancellationToken cancellationToken)
    {
        var exists = await Docker(["ps", "--all", "--filter", $"name=^{container}$", "--format", "{{.Names}}"], cancellationToken);
        if (!string.IsNullOrWhiteSpace(exists))
        {
            await Docker(["rm", "--force", container], cancellationToken);
        }
    }

    private static async Task<string> Docker(string[] arguments, CancellationToken cancellationToken)
    {
        var start = new ProcessStartInfo("docker") { RedirectStandardOutput = true, RedirectStandardError = true, UseShellExecute = false };
        foreach (var argument in arguments)
        {
            start.ArgumentList.Add(argument);
        }
        using var process = Process.Start(start) ?? throw new InvalidOperationException("Could not start Docker.");
        var output = process.StandardOutput.ReadToEndAsync(cancellationToken);
        var error = process.StandardError.ReadToEndAsync(cancellationToken);
        await process.WaitForExitAsync(cancellationToken);
        Require(process.ExitCode == 0, "Docker cleanup/inspection failed.");
        return await output + await error;
    }

    private static async Task CheckLogs(string container, string[] secrets, CancellationToken cancellationToken)
    {
        var logs = await Docker(["logs", container], cancellationToken);
        Require(!string.IsNullOrWhiteSpace(logs), "Migration produced no diagnostic output.");
        foreach (var secret in secrets)
        {
            Require(!logs.Contains(secret, StringComparison.Ordinal), "Migration diagnostics disclosed a credential.");
        }
    }

    private static void Require(bool condition, string message)
    {
        if (!condition)
        {
            throw new InvalidOperationException(message);
        }
    }
}
