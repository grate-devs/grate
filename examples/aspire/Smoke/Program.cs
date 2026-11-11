using System.Diagnostics;
using System.Security.Cryptography;
using Aspire.Hosting;
using Aspire.Hosting.ApplicationModel;
using Grate.Aspire.Hosting;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Diagnostics.HealthChecks;
using Microsoft.Extensions.Logging;
using Npgsql;

var selected = args.Length == 0 ? "all" : args[0];
var scenarios = new[] { "success", "retained", "sql-failure", "credentials-failure", "readiness", "interruption" };
if (selected != "all" && !scenarios.Contains(selected, StringComparer.Ordinal))
{
    throw new ArgumentException("Choose all, success, retained, sql-failure, credentials-failure, readiness or interruption.");
}

foreach (var scenario in scenarios.Where(scenario => selected == "all" || scenario == selected))
{
    await RunScenario(scenario);
    Console.WriteLine($"PASS: {scenario}");
}

static async Task RunScenario(string scenario)
{
    using var timeout = new CancellationTokenSource(TimeSpan.FromMinutes(3));
    var cancellationToken = timeout.Token;
    var identity = Guid.NewGuid().ToString("N");
    var volume = $"grate-aspire-smoke-{identity}";
    var directory = Path.Combine(Path.GetTempPath(), $"grate aspire smoke {identity}");
    var scripts = Path.Combine(directory, "sql scripts");
    Directory.CreateDirectory(Path.Combine(scripts, "up"));
    var sql = scenario switch
    {
        "sql-failure" => "THIS IS NOT VALID SQL;",
        "interruption" => "SELECT pg_sleep(120);",
        _ => "CREATE TABLE public.aspire_demo (id integer PRIMARY KEY, message text NOT NULL);\nINSERT INTO public.aspire_demo VALUES (1, 'Hello from grate');"
    };
    await File.WriteAllTextAsync(Path.Combine(scripts, "up", "001_create_demo.sql"), sql, cancellationToken);
    var password = RandomNumberGenerator.GetHexString(32);
    try
    {
        var firstHistory = await RunApplication(scenario, scripts, volume, password, cancellationToken);
        if (scenario == "retained")
        {
            var secondHistory = await RunApplication("success", scripts, volume, password, cancellationToken);
            Require(firstHistory == secondHistory, "Retained restart changed one-time script history.");
        }
    }
    finally
    {
        await Docker(["volume", "rm", "--force", volume], CancellationToken.None);
        Directory.Delete(directory, recursive: true);
    }
}

static async Task<string?> RunApplication(
    string scenario, string scripts, string volume, string password, CancellationToken cancellationToken)
{
    var identity = Guid.NewGuid().ToString("N");
    var migrationContainer = $"grate-aspire-migrate-{identity}";
    var databaseContainer = $"grate-aspire-postgres-{identity}";
    var builder = DistributedApplication.CreateBuilder(new DistributedApplicationOptions
    {
        Args = [],
        DisableDashboard = true
    });
    builder.Services.AddLogging(logging =>
    {
        logging.ClearProviders();
        logging.AddConsole();
        logging.SetMinimumLevel(LogLevel.Critical);
    });
    var readiness = new ReadinessGate { Open = scenario != "readiness" };
    builder.Services.AddHealthChecks().AddCheck("smoke-readiness", () => readiness.Open
        ? HealthCheckResult.Healthy() : HealthCheckResult.Unhealthy("Waiting for the smoke test gate."));
    var secret = builder.AddParameter("password", password, secret: true);
    var postgres = builder.AddPostgres("postgres", password: secret)
        .WithImageTag("16")
        .WithContainerName(databaseContainer)
        .WithDataVolume(volume)
        .WithHealthCheck("smoke-readiness");
    var database = postgres.AddDatabase("appdb");
    var migrate = database.AddGrateMigration()
        .WithScriptsFolder(scripts, containerPath: "/sql scripts")
        .WithContainerName(migrationContainer);
    if (scenario == "credentials-failure")
    {
        migrate.WithEnvironment("APP_CONNSTRING", ReferenceExpression.Create(
            $"Host={postgres.GetEndpoint("tcp").Property(EndpointProperty.Host)};Port={postgres.GetEndpoint("tcp").Property(EndpointProperty.Port)};Database=appdb;Username=postgres;Password=deliberately-wrong"));
    }
    var api = builder.AddProject<Projects.Api>("api")
        .WithHttpEndpoint(name: "http")
        .WithReference(database)
        .WithHttpHealthCheck("/health")
        .WaitForCompletion(migrate);
    await using var app = builder.Build();
    var notifications = app.Services.GetRequiredService<ResourceNotificationService>();
    using var startup = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
    Task? starting = null;
    try
    {
        starting = app.StartAsync(startup.Token);
        if (scenario == "readiness")
        {
            // Establish that PostgreSQL accepts SQL while the custom readiness gate
            // stays closed, rather than mistaking ordinary server startup for a gate.
            await WaitForMaintenanceDatabase(database, cancellationToken);
            Require(!notifications.TryGetCurrentState(migrate.Resource.Name, out var beforeGate)
                || beforeGate.Snapshot.ExitCode is null, "Migration completed before database readiness.");
            Require(!notifications.TryGetCurrentState("api", out var beforeApi)
                || beforeApi.Snapshot.State?.Text != KnownResourceStates.Running,
                "API started while the database readiness gate was closed.");
            Require(string.IsNullOrWhiteSpace(await Docker(
                ["ps", "--all", "--filter", $"name=^{migrationContainer}$", "--format", "{{.Names}}"], cancellationToken)),
                "Migration container started while the readiness gate was closed.");
            readiness.Open = true;
        }
        if (scenario == "interruption")
        {
            await notifications.WaitForResourceAsync(migrate.Resource.Name, KnownResourceStates.Running, cancellationToken);
            await using var connection = await OpenDatabase(database, cancellationToken);
            await WaitForActiveMigration(connection, cancellationToken);
            await notifications.WaitForResourceAsync("api", KnownResourceStates.Waiting, cancellationToken);
            await CheckLogs(migrationContainer, password, cancellationToken);
            return null;
        }

        await starting;

        var completion = await notifications.WaitForResourceAsync(migrate.Resource.Name,
            resource => resource.Snapshot.ExitCode.HasValue, cancellationToken);
        if (scenario is "sql-failure" or "credentials-failure")
        {
            Require(completion.Snapshot.ExitCode != 0, "A deliberately failing migration returned success.");
            await notifications.WaitForResourceAsync("api", KnownResourceStates.FailedToStart, cancellationToken);
            await CheckLogs(migrationContainer, password, cancellationToken);
            if (scenario == "credentials-failure")
            {
                await CheckLogs(migrationContainer, "deliberately-wrong", cancellationToken);
            }
            if (scenario == "sql-failure")
            {
                await using var connection = await OpenDatabase(database, cancellationToken);
                await using var errors = new NpgsqlCommand("SELECT count(*) FROM grate.\"ScriptsRunErrors\"", connection);
                Require((long?)await errors.ExecuteScalarAsync(cancellationToken) > 0, "SQL failure did not leave a migration error row.");
            }
            return null;
        }

        Require(completion.Snapshot.ExitCode == 0, "Migration failed.");
        await notifications.WaitForResourceHealthyAsync("api", cancellationToken);
        using var client = new HttpClient { BaseAddress = new Uri(api.GetEndpoint("http").Url) };
        Require(await client.GetStringAsync("/", cancellationToken) == "Hello from grate", "API did not return the migrated row.");
        await using var successfulConnection = await OpenDatabase(database, cancellationToken);
        await using var data = new NpgsqlCommand("SELECT count(*) FROM public.aspire_demo", successfulConnection);
        Require((long?)await data.ExecuteScalarAsync(cancellationToken) == 1, "Unexpected seed row count.");
        await using var history = new NpgsqlCommand(
            "SELECT count(*)::text || ':' || min(id)::text || ':' || min(text_hash) FROM grate.\"ScriptsRun\" WHERE script_name = '001_create_demo.sql' AND one_time_script", successfulConnection);
        var fingerprint = (string?)await history.ExecuteScalarAsync(cancellationToken);
        Require(fingerprint?.StartsWith("1:", StringComparison.Ordinal) == true, "Expected exactly one one-time script history row.");
        await CheckLogs(migrationContainer, password, cancellationToken);
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
                // Stopping an AppHost while its migration runs may cancel startup.
            }
        }
        await WaitForContainerExit(migrationContainer, shutdown.Token);
        await WaitForContainerExit(databaseContainer, shutdown.Token);
    }
}

static async Task<NpgsqlConnection> OpenDatabase(
    IResourceBuilder<PostgresDatabaseResource> database, CancellationToken cancellationToken)
{
    var connection = new NpgsqlConnection(await database.Resource.ConnectionStringExpression.GetValueAsync(cancellationToken));
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

static async Task WaitForActiveMigration(NpgsqlConnection connection, CancellationToken cancellationToken)
{
    using var poll = new PeriodicTimer(TimeSpan.FromMilliseconds(200));
    do
    {
        await using var command = new NpgsqlCommand(
            "SELECT EXISTS (SELECT 1 FROM pg_stat_activity WHERE pid <> pg_backend_pid() AND state = 'active' AND query LIKE '%pg_sleep(120)%')", connection);
        if ((bool?)await command.ExecuteScalarAsync(cancellationToken) == true)
        {
            return;
        }
    } while (await poll.WaitForNextTickAsync(cancellationToken));
}

static async Task WaitForMaintenanceDatabase(
    IResourceBuilder<PostgresDatabaseResource> database, CancellationToken cancellationToken)
{
    var connectionString = new NpgsqlConnectionStringBuilder(
        await database.Resource.ConnectionStringExpression.GetValueAsync(cancellationToken))
    {
        Database = "postgres",
        Timeout = 1
    };
    using var poll = new PeriodicTimer(TimeSpan.FromMilliseconds(200));
    do
    {
        try
        {
            await using var connection = new NpgsqlConnection(connectionString.ConnectionString);
            await connection.OpenAsync(cancellationToken);
            await using var command = new NpgsqlCommand("SELECT 1", connection);
            Require((int?)await command.ExecuteScalarAsync(cancellationToken) == 1, "PostgreSQL did not accept the readiness probe.");
            return;
        }
        catch (NpgsqlException) when (!cancellationToken.IsCancellationRequested)
        {
            // Retry only the independent server-start probe, never a migration.
        }
    } while (await poll.WaitForNextTickAsync(cancellationToken));
}

static async Task CheckLogs(string container, string password, CancellationToken cancellationToken)
{
    var logs = await Docker(["logs", container], cancellationToken);
    Require(!logs.Contains(password, StringComparison.Ordinal), "Migration output disclosed the database password.");
    Require(!string.IsNullOrWhiteSpace(logs), "Migration container produced no diagnostic output.");
}

static async Task WaitForContainerExit(string container, CancellationToken cancellationToken)
{
    using var poll = new PeriodicTimer(TimeSpan.FromMilliseconds(200));
    do
    {
        var result = await Docker(["ps", "--all", "--filter", $"name=^{container}$", "--format", "{{.Names}}"], cancellationToken);
        if (string.IsNullOrWhiteSpace(result))
        {
            return;
        }
    } while (await poll.WaitForNextTickAsync(cancellationToken));
    throw new InvalidOperationException("A smoke-test container was left running after shutdown.");
}

static async Task<string> Docker(string[] arguments, CancellationToken cancellationToken)
{
    var start = new ProcessStartInfo("docker")
    {
        RedirectStandardOutput = true,
        RedirectStandardError = true,
        UseShellExecute = false
    };
    foreach (var argument in arguments)
    {
        start.ArgumentList.Add(argument);
    }
    using var process = Process.Start(start) ?? throw new InvalidOperationException("Could not start Docker.");
    var output = process.StandardOutput.ReadToEndAsync(cancellationToken);
    var error = process.StandardError.ReadToEndAsync(cancellationToken);
    await process.WaitForExitAsync(cancellationToken);
    if (process.ExitCode != 0)
    {
        throw new InvalidOperationException($"Docker cleanup/inspection failed: {await error}");
    }
    return await output + await error;
}

static void Require(bool condition, string message)
{
    if (!condition)
    {
        throw new InvalidOperationException(message);
    }
}

internal sealed class ReadinessGate
{
    public volatile bool Open;
}
