using System.Diagnostics;
using System.Globalization;
using System.Security.Cryptography;
using Aspire.Hosting;
using Aspire.Hosting.ApplicationModel;
using Grate.Aspire.Hosting;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Logging;
using MySqlConnector;

var selected = args.Length == 0 ? "all" : args[0];
string[] scenarios = ["success", "retained", "sql-failure", "credentials-failure"];
if (selected != "all" && !scenarios.Contains(selected, StringComparer.Ordinal))
{
    throw new ArgumentException("Choose all, success, retained, sql-failure or credentials-failure.");
}
foreach (var scenario in scenarios.Where(scenario => selected == "all" || scenario == selected))
{
    await MySqlSmoke.Run(scenario);
    Console.WriteLine($"PASS: mysql {scenario}");
}

internal static class MySqlSmoke
{
    public static async Task Run(string scenario)
    {
        using var timeout = new CancellationTokenSource(TimeSpan.FromMinutes(4));
        var identity = Guid.NewGuid().ToString("N");
        var directory = Directory.CreateTempSubdirectory("grate aspire mysql smoke ").FullName;
        var scripts = Directory.CreateDirectory(Path.Combine(directory, "sql scripts")).FullName;
        Directory.CreateDirectory(Path.Combine(scripts, "up"));
        var volume = $"grate-aspire-mysql-smoke-{identity}";
        var password = $"Grate1!{RandomNumberGenerator.GetHexString(32)}";
        var sql = scenario == "sql-failure" ? "THIS IS NOT VALID SQL;"
            : "CREATE TABLE aspire_demo (id INT PRIMARY KEY, message VARCHAR(200) NOT NULL);\nINSERT INTO aspire_demo VALUES (1, 'Hello from grate');";
        await File.WriteAllTextAsync(Path.Combine(scripts, "up", "001_create_demo.sql"), sql, timeout.Token);
        try
        {
            Require(string.IsNullOrWhiteSpace(await Docker(["volume", "ls", "--filter", $"name=^{volume}$", "--format", "{{.Name}}"], timeout.Token)),
                "Fresh scenario unexpectedly reused a database volume.");
            var first = await RunApplication(scenario, scripts, volume, password, timeout.Token);
            if (scenario == "retained")
            {
                var second = await RunApplication("success", scripts, volume, password, timeout.Token);
                Require(first == second, "Retained restart changed the one-time history identity/hash.");
            }
        }
        finally
        {
            MySqlConnection.ClearAllPools();
            using var cleanup = new CancellationTokenSource(TimeSpan.FromSeconds(30));
            await Docker(["volume", "rm", "--force", volume], cleanup.Token);
            Directory.Delete(directory, recursive: true);
        }
    }

    private static async Task<string?> RunApplication(
        string scenario, string scripts, string volume, string password, CancellationToken cancellationToken)
    {
        var identity = Guid.NewGuid().ToString("N");
        var migrationContainer = $"grate-aspire-mysql-migration-{identity}";
        var serverContainer = $"grate-aspire-mysql-server-{identity}";
        var builder = DistributedApplication.CreateBuilder(new DistributedApplicationOptions { Args = [], DisableDashboard = true });
        builder.Services.AddLogging(logging =>
        {
            logging.ClearProviders();
            logging.AddConsole();
            logging.SetMinimumLevel(LogLevel.Critical);
        });
        var secret = builder.AddParameter("password", password, secret: true);
        var server = builder.AddMySql("mysql", password: secret)
            .WithImageTag("8.4.13")
            .WithContainerName(serverContainer)
            .WithDataVolume(volume);
        var database = server.AddDatabase("appdb")
            .WithCreationScript("CREATE DATABASE IF NOT EXISTS appdb; CREATE TABLE IF NOT EXISTS appdb.native_provisioning (id INT PRIMARY KEY);");
        var migration = database.AddGrateMigration()
            .WithScriptsFolder(scripts, containerPath: "/sql scripts")
            .WithContainerName(migrationContainer);
        if (scenario == "credentials-failure")
        {
            migration.WithEnvironment("APP_CONNSTRING", ReferenceExpression.Create(
                $"Server={server.GetEndpoint("tcp").Property(EndpointProperty.Host)};Port={server.GetEndpoint("tcp").Property(EndpointProperty.Port)};Database=appdb;User ID=root;Password=deliberately-wrong;Connection Timeout=5"));
        }
        var api = builder.AddProject<Projects.Api>("api")
            .WithHttpEndpoint(name: "http")
            .WithReference(database)
            .WithHttpHealthCheck("/health")
            .WaitForCompletion(migration);
        await using var app = builder.Build();
        var notifications = app.Services.GetRequiredService<ResourceNotificationService>();
        try
        {
            await app.StartAsync(cancellationToken);
            var completion = await notifications.WaitForResourceAsync(migration.Resource.Name,
                resource => resource.Snapshot.ExitCode.HasValue, cancellationToken);
            var logs = await Docker(["logs", migrationContainer], cancellationToken);
            Require(!string.IsNullOrWhiteSpace(logs), "Migration produced no diagnostic output.");
            Require(!logs.Contains(password, StringComparison.Ordinal) && !logs.Contains("deliberately-wrong", StringComparison.Ordinal),
                "Migration diagnostics disclosed a credential.");
            await using var connection = new MySqlConnection(await database.Resource.ConnectionStringExpression.GetValueAsync(cancellationToken));
            await connection.OpenAsync(cancellationToken);
            Require(await Scalar(connection, "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema = 'appdb' AND table_name = 'native_provisioning'", cancellationToken) == 1,
                "Native Aspire database provisioning did not finish before migration.");
            if (scenario is "sql-failure" or "credentials-failure")
            {
                Require(completion.Snapshot.ExitCode != 0, "Deliberately failing migration returned success.");
                await notifications.WaitForResourceAsync("api", KnownResourceStates.FailedToStart, cancellationToken);
                Require(await Scalar(connection, "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema = 'appdb' AND table_name = 'aspire_demo'", cancellationToken) == 0,
                    "Failed migration unexpectedly created the application table.");
                if (scenario == "sql-failure")
                {
                    Require(await Scalar(connection, "SELECT COUNT(*) FROM grate_ScriptsRunErrors", cancellationToken) > 0,
                        "SQL failure left no error history.");
                }
                return null;
            }
            Require(completion.Snapshot.ExitCode == 0, "Migration failed.");
            await notifications.WaitForResourceHealthyAsync("api", cancellationToken);
            using var client = new HttpClient { BaseAddress = new Uri(api.GetEndpoint("http").Url) };
            Require(await client.GetStringAsync("/", cancellationToken) == "Hello from grate", "API did not read the migrated seed row.");
            Require(await Scalar(connection, "SELECT COUNT(*) FROM aspire_demo", cancellationToken) == 1, "Unexpected seed row count.");
            Require(await Scalar(connection, "SELECT COUNT(*) FROM grate_ScriptsRunErrors", cancellationToken) == 0, "Successful migration recorded SQL errors.");
            await using var history = connection.CreateCommand();
            history.CommandText = "SELECT id, text_hash FROM grate_ScriptsRun WHERE script_name = '001_create_demo.sql' AND one_time_script = 1";
            await using var reader = await history.ExecuteReaderAsync(cancellationToken);
            Require(await reader.ReadAsync(cancellationToken), "One-time history missing.");
            var fingerprint = $"{reader.GetValue(0)}:{reader.GetString(1)}";
            Require(!await reader.ReadAsync(cancellationToken), "Duplicate one-time history row.");
            return fingerprint;
        }
        finally
        {
            using var shutdown = new CancellationTokenSource(TimeSpan.FromSeconds(45));
            await app.StopAsync(shutdown.Token);
            await WaitForRemoval(migrationContainer, shutdown.Token);
            await WaitForRemoval(serverContainer, shutdown.Token);
        }
    }

    private static async Task<long> Scalar(MySqlConnection connection, string sql, CancellationToken cancellationToken)
    {
        await using var command = connection.CreateCommand();
        command.CommandText = sql;
        return Convert.ToInt64(await command.ExecuteScalarAsync(cancellationToken), CultureInfo.InvariantCulture);
    }

    private static async Task WaitForRemoval(string container, CancellationToken cancellationToken)
    {
        using var poll = new PeriodicTimer(TimeSpan.FromMilliseconds(200));
        do
        {
            if (string.IsNullOrWhiteSpace(await Docker(["ps", "--all", "--filter", $"name=^{container}$", "--format", "{{.Names}}"], cancellationToken)))
            {
                return;
            }
        } while (await poll.WaitForNextTickAsync(cancellationToken));
        throw new InvalidOperationException("Smoke container remained after shutdown.");
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
        try
        {
            await process.WaitForExitAsync(cancellationToken);
        }
        catch (OperationCanceledException)
        {
            process.Kill(entireProcessTree: true);
            throw;
        }
        Require(process.ExitCode == 0, $"Docker cleanup/inspection failed: {await error}");
        return await output + await error;
    }

    private static void Require(bool condition, string message)
    {
        if (!condition)
        {
            throw new InvalidOperationException(message);
        }
    }
}
