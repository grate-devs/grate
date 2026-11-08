using System.Diagnostics;
using DotNet.Testcontainers.Builders;
using DotNet.Testcontainers.Containers;
using Testcontainers.MsSql;
using Xunit;
using Xunit.Abstractions;
using Xunit.Sdk;

namespace Tests;

/// <summary>
/// Helper class to run a SqlServer as part of the tests for migrations etc.  One 'server' per run instance.
/// We run the grate migration as part of standing up the server so we have a fully populated database to test against.
/// </summary>
public sealed class SqlServerFixture : IAsyncLifetime
{
    private static MsSqlContainer SqlServer { get; }
    
    /// <summary>
    /// The fully privileged sa connection string to our test database
    /// </summary>
    internal static string SysAdminConnString => SqlServer.GetConnectionString().Replace("Database=master", "Database=MyApp_IntegrationTests");
    // Note: When testing real apps we often also have connection strings with application credentials in order to test permissions as part of the tests
    
    /// <summary>
    /// This lets us pass messages to the xunit output window, in theory.
    /// </summary>
    private readonly IMessageSink _sink;

    public SqlServerFixture(IMessageSink sink)
    {
        _sink = sink;
    }
    
    static SqlServerFixture()
    {
        SqlServer = new MsSqlBuilder("mcr.microsoft.com/mssql/server:2022-CU14-ubuntu-22.04") // TestContainers recommend running a pinned image for repeatability
            
            // See https://github.com/testcontainers/testcontainers-dotnet/issues/1220#issuecomment-2248455959
            .WithWaitStrategy(Wait.ForUnixContainer().UntilCommandIsCompleted("/opt/mssql-tools18/bin/sqlcmd", "-C", "-Q", "SELECT 1;") )
            .Build();
    }
    
    public async Task InitializeAsync()
    {
        await SqlServer.StartAsync();
        Assert.Equal(TestcontainersStates.Running, SqlServer.State);
        await RunDatabaseMigration();
    }

    public async Task DisposeAsync()
    {
        if (SqlServer.State == TestcontainersStates.Running)
        {
            await SqlServer.StopAsync();
        }

        await SqlServer.DisposeAsync();
    }

    private async Task RunDatabaseMigration(CancellationToken token = default)
    {
        var migration = new Process();
        migration.StartInfo.RedirectStandardOutput = true;
        migration.StartInfo.RedirectStandardError = true;
        migration.StartInfo.CreateNoWindow = true;
        migration.ErrorDataReceived += migration_OutputDataReceived;
        migration.OutputDataReceived += migration_OutputDataReceived;
        migration.EnableRaisingEvents = true;

        migration.StartInfo.Arguments = $"--files=./db --env=IntegrationTest --connstring=\"{SysAdminConnString}\" --version=1.0 --silent ";

        migration.StartInfo.FileName = OperatingSystem.IsWindows() ? "grate.exe" : "grate";

        migration.Start();

        migration.BeginOutputReadLine();
        migration.BeginErrorReadLine();

        await migration.WaitForExitAsync(token);

        Assert.True(migration.HasExited);
        Assert.Equal(0, migration.ExitCode);
    }
    
    private void migration_OutputDataReceived(object sender, DataReceivedEventArgs e)
    {
        _sink.OnMessage(new DiagnosticMessage(e.Data));
    }
}


[CollectionDefinition(nameof(SqlServerCollection))]
public class SqlServerCollection : ICollectionFixture<SqlServerFixture>
{
    // This class has no code, and is never created. Its purpose is simply
    // to be the place to apply [CollectionDefinition] and all the
    // ICollectionFixture<> interfaces so the unit tests can opt in to the database infrastructure.
}
