using System.Data.Common;
using System.Diagnostics;
using System.Globalization;
using System.Security.Cryptography;
using Aspire.Hosting;
using Aspire.Hosting.ApplicationModel;
using Grate.Aspire.Hosting;
using Microsoft.Data.SqlClient;
using Microsoft.Data.Sqlite;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Logging;

internal static class ProviderSmoke
{
    public static async Task Run(string provider, string[] args)
    {
        var selected = args.Length == 0 ? "all" : args[0];
        var scenarios = provider == "sqlite"
            ? new[] { "success", "retained", "sql-failure" }
            : ["success", "retained", "sql-failure", "credentials-failure"];
        if (selected != "all" && !scenarios.Contains(selected, StringComparer.Ordinal))
        {
            throw new ArgumentException($"Unsupported {provider} smoke scenario.");
        }
        foreach (var scenario in scenarios.Where(scenario => selected == "all" || scenario == selected))
        {
            await RunScenario(provider, scenario);
            Console.WriteLine($"PASS: {provider} {scenario}");
        }
    }

    private static async Task RunScenario(string provider, string scenario)
    {
        using var timeout = new CancellationTokenSource(TimeSpan.FromMinutes(3));
        var identity = Guid.NewGuid().ToString("N");
        var directory = Path.Combine(Path.GetTempPath(), $"grate aspire {provider} smoke {identity}");
        var scripts = Path.Combine(directory, "sql scripts");
        var data = Path.Combine(directory, "database files");
        var volume = $"grate-aspire-{provider}-smoke-{identity}";
        Directory.CreateDirectory(Path.Combine(scripts, "up"));
        Directory.CreateDirectory(data);
        var table = provider == "sqlite" ? "aspire_demo" : "dbo.aspire_demo";
        var sql = scenario == "sql-failure" ? "THIS IS NOT VALID SQL;"
            : $"CREATE TABLE {table} (id INT PRIMARY KEY, message VARCHAR(200) NOT NULL);\nINSERT INTO {table} VALUES (1, 'Hello from grate');";
        await File.WriteAllTextAsync(Path.Combine(scripts, "up", "001_create_demo.sql"), sql, timeout.Token);
        var password = $"Grate1!{RandomNumberGenerator.GetHexString(32)}";
        try
        {
            var first = await RunApplication(provider, scenario, scripts, data, volume, password, timeout.Token);
            if (scenario == "retained")
            {
                var second = await RunApplication(provider, "success", scripts, data, volume, password, timeout.Token);
                Require(first == second, "Retained restart changed one-time history identity/hash.");
            }
        }
        finally
        {
            if (provider == "sqlserver")
            {
                using var cleanup = new CancellationTokenSource(TimeSpan.FromSeconds(30));
                await Docker(["volume", "rm", "--force", volume], cleanup.Token);
            }
            SqliteConnection.ClearAllPools();
            Directory.Delete(directory, recursive: true);
        }
    }

    private static async Task<string?> RunApplication(
        string provider, string scenario, string scripts, string data, string volume,
        string password, CancellationToken cancellationToken)
    {
        var identity = Guid.NewGuid().ToString("N");
        var migrationContainer = $"grate-aspire-{provider}-migration-{identity}";
        var serverContainer = $"grate-aspire-{provider}-server-{identity}";
        var builder = DistributedApplication.CreateBuilder(new DistributedApplicationOptions { Args = [], DisableDashboard = true });
        builder.Services.AddLogging(logging =>
        {
            logging.ClearProviders();
            logging.AddConsole();
            logging.SetMinimumLevel(LogLevel.Critical);
        });
        IResourceBuilder<IResourceWithConnectionString> database;
        IResourceBuilder<GrateMigrationResource> migration;
        if (provider == "sqlite")
        {
            var sqlite = builder.AddSqlite("appdb", data, "demo.db");
            database = sqlite;
            migration = sqlite.AddGrateMigration().WithScriptsFolder(scripts, containerPath: "/sql scripts");
            Require(builder.Resources.OfType<ContainerResource>().Count() == 1,
                "SQLite must have only the migration container, without a fake database server.");
        }
        else
        {
            var secret = builder.AddParameter("password", password, secret: true);
            var server = builder.AddSqlServer("sqlserver", password: secret)
                .WithImageTag("2022-latest")
                .WithContainerRuntimeArgs("--platform", "linux/amd64")
                .WithContainerName(serverContainer)
                .WithDataVolume(volume);
            var sqlserver = server.AddDatabase("appdb");
            database = sqlserver;
            migration = sqlserver.AddGrateMigration().WithScriptsFolder(scripts, containerPath: "/sql scripts");
            if (scenario == "credentials-failure")
            {
                migration.WithEnvironment("APP_CONNSTRING", ReferenceExpression.Create(
                    $"Server={server.GetEndpoint("tcp").Property(EndpointProperty.Host)},{server.GetEndpoint("tcp").Property(EndpointProperty.Port)};Database=appdb;User ID=sa;Password=deliberately-wrong;TrustServerCertificate=true"));
            }
        }
        migration.WithContainerName(migrationContainer);
        var api = builder.AddProject<Projects.Api>("api")
            .WithEnvironment("DatabaseProvider", provider)
            .WithHttpEndpoint(name: "http")
            .WithReference(database)
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
            var secrets = provider == "sqlserver" ? new[] { password, "deliberately-wrong" } : [];
            await CheckLogs(migrationContainer, secrets, cancellationToken);
            if (scenario is "sql-failure" or "credentials-failure")
            {
                Require(completion.Snapshot.ExitCode != 0, "Deliberately failing migration returned success.");
                await notifications.WaitForResourceAsync("api", KnownResourceStates.FailedToStart, cancellationToken);
                if (scenario == "sql-failure")
                {
                    await using var connection = await OpenDatabase(provider, database, cancellationToken);
                    await using var errors = connection.CreateCommand();
                    errors.CommandText = provider == "sqlite" ? "SELECT COUNT(*) FROM grate_ScriptsRunErrors" : "SELECT COUNT(*) FROM grate.ScriptsRunErrors";
                    Require(Convert.ToInt64(await errors.ExecuteScalarAsync(cancellationToken), CultureInfo.InvariantCulture) > 0,
                        "SQL failure left no error history.");
                }
                return null;
            }
            Require(completion.Snapshot.ExitCode == 0, "Migration failed.");
            await notifications.WaitForResourceHealthyAsync("api", cancellationToken);
            using var client = new HttpClient { BaseAddress = new Uri(api.GetEndpoint("http").Url) };
            Require(await client.GetStringAsync("/", cancellationToken) == "Hello from grate", "API did not read the migrated seed row.");
            await using var successful = await OpenDatabase(provider, database, cancellationToken);
            await using var count = successful.CreateCommand();
            count.CommandText = provider == "sqlite" ? "SELECT COUNT(*) FROM aspire_demo" : "SELECT COUNT(*) FROM dbo.aspire_demo";
            Require(Convert.ToInt64(await count.ExecuteScalarAsync(cancellationToken), CultureInfo.InvariantCulture) == 1, "Unexpected seed row count.");
            if (provider == "sqlite")
            {
                await VerifyHostSqliteWrite(successful, cancellationToken);
            }
            await using var history = successful.CreateCommand();
            history.CommandText = provider == "sqlite"
                ? "SELECT id, text_hash FROM grate_ScriptsRun WHERE script_name = '001_create_demo.sql' AND one_time_script = 1"
                : "SELECT id, text_hash FROM grate.ScriptsRun WHERE script_name = '001_create_demo.sql' AND one_time_script = 1";
            await using var reader = await history.ExecuteReaderAsync(cancellationToken);
            Require(await reader.ReadAsync(cancellationToken), "One-time history missing.");
            var fingerprint = $"{reader.GetValue(0)}:{reader.GetString(1)}";
            Require(!await reader.ReadAsync(cancellationToken), "Duplicate one-time history row.");
            return fingerprint;
        }
        finally
        {
            using var shutdown = new CancellationTokenSource(TimeSpan.FromSeconds(45));
            startup.Cancel();
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
            await WaitForRemoval(migrationContainer, shutdown.Token);
            if (provider == "sqlserver")
            {
                await WaitForRemoval(serverContainer, shutdown.Token);
            }
        }
    }

    private static async Task<DbConnection> OpenDatabase(
        string provider, IResourceBuilder<IResourceWithConnectionString> database, CancellationToken cancellationToken)
    {
        var value = await database.Resource.ConnectionStringExpression.GetValueAsync(cancellationToken);
        DbConnection connection = provider == "sqlite" ? new SqliteConnection(value) : new SqlConnection(value);
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

    private static async Task VerifyHostSqliteWrite(DbConnection connection, CancellationToken cancellationToken)
    {
        // Reading a root-owned 0644 file can succeed on Linux while application
        // writes fail. Exercise both the database file and journal directory.
        await using (var transaction = await connection.BeginTransactionAsync(cancellationToken))
        {
            await using var insert = connection.CreateCommand();
            insert.Transaction = transaction;
            insert.CommandText = "INSERT INTO aspire_demo (id, message) VALUES (2, 'Host write probe')";
            Require(await insert.ExecuteNonQueryAsync(cancellationToken) == 1, "Host SQLite write did not insert the probe row.");
            await using var read = connection.CreateCommand();
            read.Transaction = transaction;
            read.CommandText = "SELECT message FROM aspire_demo WHERE id = 2";
            Require((string?)await read.ExecuteScalarAsync(cancellationToken) == "Host write probe", "Host SQLite write was not readable within its transaction.");
            await transaction.RollbackAsync(cancellationToken);
        }
        await using var verifyRollback = connection.CreateCommand();
        verifyRollback.CommandText = "SELECT COUNT(*) FROM aspire_demo WHERE id = 2";
        Require(Convert.ToInt64(await verifyRollback.ExecuteScalarAsync(cancellationToken), CultureInfo.InvariantCulture) == 0,
            "SQLite write probe changed the retained seed data.");
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
        await process.WaitForExitAsync(cancellationToken);
        Require(process.ExitCode == 0, $"Docker cleanup/inspection failed: {await error}");
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
