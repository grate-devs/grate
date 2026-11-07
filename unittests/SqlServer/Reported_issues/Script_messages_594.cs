using SqlServer.TestInfrastructure;
using TestCommon.TestInfrastructure;

namespace SqlServer.Reported_issues;

[Collection(nameof(SqlServerGrateTestContext))]
public sealed class Script_messages_594(SqlServerGrateTestContext context) : IAsyncLifetime
{
    private readonly string _database = TestConfig.RandomDatabase();
    private readonly DirectoryInfo _root = Directory.CreateTempSubdirectory("grate-sqlserver-messages-");

    [Fact]
    public async Task Debug_logs_server_messages_from_default_and_autonomous_connections()
    {
        WriteScript("up", "first.sql", """
            PRINT CONCAT('up-', 20 + 22);
            GO
            RAISERROR('info-%d', 10, 1, 43);
            """);
        WriteScript("alterDatabase", "admin.sql", "PRINT CONCAT('admin-', 20 + 24);");
        WriteScript("afterMigration", "seed.sql", """
            PRINT CONCAT('seed-', 20 + 25, CHAR(10), '::error::injected', CHAR(10),
                         '##vso[task.setvariable variable=injected] ##teamcity[buildProblem]');
            """);

        var (exitCode, output) = await Migrate("--verbosity=Debug", "--transaction");

        Assert.Equal(0, exitCode);
        Assert.Single(Lines(output), line => line == "[DEBUG] SQL Server (first.sql): up-42");
        Assert.Single(Lines(output), line => line == "[DEBUG] SQL Server (first.sql): info-43");
        Assert.Single(Lines(output), line => line == "[DEBUG] SQL Server (admin.sql): admin-44");
        Assert.Single(Lines(output), line => line == "[DEBUG] SQL Server (seed.sql): seed-45");
        Assert.Contains("[DEBUG] ::error::injected", Lines(output));
        Assert.DoesNotContain(Lines(output), line => line.StartsWith("::error::", StringComparison.Ordinal));
        Assert.DoesNotContain("##vso[", output);
        Assert.DoesNotContain("##teamcity[", output);
    }

    [Fact]
    public async Task Default_verbosity_and_dry_run_do_not_log_server_messages()
    {
        const string script = "seed.sql";
        WriteScript("afterMigration", script, "PRINT CONCAT('seed-', 30 + 16);");

        var (defaultExit, defaultOutput) = await Migrate();
        Assert.Equal(0, defaultExit);
        Assert.Contains("Running 'seed.sql'", defaultOutput);
        Assert.DoesNotContain("seed-46", defaultOutput);

        var (dryRunExit, dryRunOutput) = await Migrate("--verbosity=Debug", "--dryrun");
        Assert.Equal(0, dryRunExit);
        Assert.Contains("DryRun 'seed.sql'", dryRunOutput);
        Assert.DoesNotContain("seed-46", dryRunOutput);
    }

    [Fact]
    public async Task A_SQL_Server_error_still_fails_the_migration_at_Debug()
    {
        WriteScript("up", "broken.sql", "RAISERROR('rejected-%d', 16, 1, 47);");

        var (exitCode, output) = await Migrate("--verbosity=Debug");

        Assert.Equal(1, exitCode);
        var annotation = Assert.Single(Lines(output), line => line.StartsWith("::error::", StringComparison.Ordinal));
        Assert.Contains("broken.sql", annotation);
        Assert.Contains("rejected-47", annotation);
        Assert.DoesNotContain("[DEBUG] SQL Server (broken.sql): rejected-47", output);
    }

    private async Task<(int ExitCode, string Output)> Migrate(params string[] options)
    {
        // This test assembly runs serially. The CI logger writes directly to the
        // stdout writer it captures when the migration starts.
        using var output = new StringWriter();
        var stdout = Console.Out;
        try
        {
            Console.SetOut(output);
            var exitCode = await grate.Program.Main([
                "--databasetype=sqlserver",
                "--connectionstring=" + context.External.ConnectionString(_database),
                "--adminconnectionstring=" + context.External.AdminConnectionString,
                "--files=" + _root.FullName,
                "--output=" + Path.Combine(_root.FullName, "output"),
                "--silent", "--log-format=github", ..options
            ]);
            return (exitCode, output.ToString());
        }
        finally
        {
            Console.SetOut(stdout);
        }
    }

    private void WriteScript(string folder, string name, string sql) =>
        File.WriteAllText(Path.Combine(_root.CreateSubdirectory(folder).FullName, name), sql);

    private static string[] Lines(string output) =>
        output.Split(['\r', '\n'], StringSplitOptions.RemoveEmptyEntries);

    public ValueTask InitializeAsync() => ValueTask.CompletedTask;

    public async ValueTask DisposeAsync()
    {
        try
        {
            await context.DropDatabase(_database);
        }
        finally
        {
            _root.Delete(recursive: true);
        }
    }
}
