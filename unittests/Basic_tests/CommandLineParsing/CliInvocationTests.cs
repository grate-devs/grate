using System.Diagnostics;
using grate;
using Microsoft.Data.Sqlite;

namespace Basic_tests.CommandLineParsing;

public sealed class CliInvocationTests
{
    [Theory]
    [InlineData(new[] { "--help" }, "--connectionstring")]
    [InlineData(new[] { "--databasetype", "999", "--help" }, "--connectionstring")]
    [InlineData(new[] { "skills", "--help" }, "install")]
    [InlineData(new[] { "skills", "install", "--help" }, "--local")]
    public async Task Help_succeeds_without_migration_configuration(string[] arguments, string expectedOption)
    {
        var result = await Invoke(arguments);

        Assert.Equal(0, result.ExitCode);
        Assert.Contains(expectedOption, result.Output);
        Assert.Empty(result.Error);
    }

    [Theory]
    [InlineData(new string[0], "--connectionstring")]
    [InlineData(new[] { "--connectionstring", "unused", "--databasetype", "invalid" }, "--databasetype")]
    [InlineData(new[] { "--connectionstring", "unused", "--commandtimeout", "invalid" }, "--commandtimeout")]
    [InlineData(new[] { "--connectionstring", "unused", "--log-format", "invalid" }, "'invalid'")]
    [InlineData(new[] { "--connectionstring", "unused", "--log-format", "1" }, "'1'")]
    public async Task Invalid_arguments_report_parse_errors_without_starting_a_migration(string[] arguments, string expectedDiagnostic)
    {
        var result = await Invoke(arguments);

        Assert.Equal(1, result.ExitCode);
        Assert.Contains(expectedDiagnostic, result.Error);
        Assert.DoesNotContain("Unhandled exception", result.Error);
        Assert.DoesNotContain("An error occurred:", result.Error);
    }

    [Fact]
    public async Task Migration_failures_keep_the_existing_error_message_and_exit_code()
    {
        var result = await Invoke("--databasetype", "sqlite", "--connectionstring", "invalid", "--silent");

        Assert.Equal(1, result.ExitCode);
        Assert.Contains("An error occurred:", result.Error);
        Assert.DoesNotContain("Unhandled exception", result.Error);
    }

    [Fact]
    public async Task Skills_install_runs_without_a_connection_string()
    {
        var root = Directory.CreateTempSubdirectory("grate-cli-skills-");
        try
        {
            var result = await Invoke("skills", "install", "--local", "--path", root.FullName);

            Assert.Equal(0, result.ExitCode);
            Assert.Empty(result.Error);
            foreach (var agent in new[] { ".agents", ".claude" })
            {
                Assert.True(File.Exists(Path.Combine(root.FullName, agent, "skills", "use-grate", "SKILL.md")));
            }
        }
        finally
        {
            root.Delete(recursive: true);
        }
    }

    [Theory]
    [InlineData("up=missing", "up", "missing")]
    [InlineData("missing", "missing", "missing")]
    [InlineData("custom=type:Once", "custom", "custom")]
    [InlineData("custom=path:.;up=Once", "up", "up")]
    [InlineData("up=up", "up", "up")]
    [InlineData("up=missing;UP=Once", "up", "missing")]
    [InlineData("views=PaTh:missing,type:AnyTime", "views", "missing")]
    [InlineData("createDatabase=missing", "createDatabase", "missing")]
    public async Task Missing_explicit_folders_fail_before_creating_the_database(string folders, string key, string path)
    {
        var root = Directory.CreateTempSubdirectory("grate-cli-folders-");
        try
        {
            var scripts = root.CreateSubdirectory("scripts");
            var database = Path.Combine(root.FullName, "test.sqlite");

            var result = await InvokeSqliteMigration(root, scripts, database, "--folders", folders);

            Assert.Equal(1, result.ExitCode);
            Assert.Contains($"'{key}'", result.Error, StringComparison.OrdinalIgnoreCase);
            Assert.Contains(Path.Combine(scripts.FullName, path), result.Error);
            Assert.False(File.Exists(database));
        }
        finally
        {
            root.Delete(recursive: true);
        }
    }

    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public async Task A_file_at_a_folder_path_from_config_fails_before_changing_the_database(bool drop)
    {
        var root = Directory.CreateTempSubdirectory("grate-cli-folders-");
        try
        {
            var scripts = root.CreateSubdirectory("scripts");
            var file = Path.Combine(scripts.FullName, "regular-file");
            File.WriteAllText(file, "This is a file.");
            scripts.CreateSubdirectory("ddl");
            var config = Path.Combine(root.FullName, "folders.txt");
            File.WriteAllText(config, "up=ddl\nviews=path:regular-file,type:AnyTime\n");
            var database = Path.Combine(root.FullName, "test.sqlite");
            using (var connection = new SqliteConnection(SqliteConnectionString(database)))
            {
                connection.Open();
                using var command = connection.CreateCommand();
                command.CommandText = "CREATE TABLE original_table (id INTEGER PRIMARY KEY)";
                command.ExecuteNonQuery();
            }
            var before = File.ReadAllBytes(database);

            var result = await InvokeSqliteMigration(root, scripts, database,
                "--folders", config, $"--drop={drop}", "--verbosity", "Critical");

            Assert.Equal(1, result.ExitCode);
            Assert.Contains("'views'", result.Error, StringComparison.OrdinalIgnoreCase);
            Assert.Contains(file, result.Error);
            Assert.Equal(before, File.ReadAllBytes(database));
        }
        finally
        {
            root.Delete(recursive: true);
        }
    }

    [Theory]
    [InlineData(null, "up")]
    [InlineData("views=AnyTime", "up")]
    [InlineData("views=type:AnyTime", "up")]
    [InlineData("up=missing;UP=path:nested/ddl scripts,type:Once;up=AnyTime", "nested/ddl scripts")]
    [InlineData("ddl=Once", "ddl")]
    public async Task Existing_configured_folders_run_with_only_the_needed_directories(string? folders, string path)
    {
        var root = Directory.CreateTempSubdirectory("grate-cli-folders-");
        try
        {
            var scripts = root.CreateSubdirectory("scripts");
            var ddl = scripts.CreateSubdirectory(path);
            File.WriteAllText(Path.Combine(ddl.FullName, "001_create_table.sql"),
                "CREATE TABLE migrated_table (id INTEGER PRIMARY KEY);");
            var database = Path.Combine(root.FullName, "test.sqlite");
            var folderArguments = folders is null ? Array.Empty<string>() : new[] { "--folders", folders };

            var result = await InvokeSqliteMigration(root, scripts, database, folderArguments);

            Assert.True(result.ExitCode == 0, result.Error);
            Assert.True(File.Exists(database));
            using var connection = new SqliteConnection(SqliteConnectionString(database));
            connection.Open();
            using var command = connection.CreateCommand();
            command.CommandText = "SELECT name FROM sqlite_master WHERE type = 'table' AND name = 'migrated_table'";
            Assert.Equal("migrated_table", command.ExecuteScalar());
        }
        finally
        {
            root.Delete(recursive: true);
        }
    }

    private static Task<(int ExitCode, string Output, string Error)> InvokeSqliteMigration(
        DirectoryInfo root, DirectoryInfo scripts, string database, params string[] arguments) => Invoke(
        ["--databasetype", "sqlite", "--connectionstring", SqliteConnectionString(database),
            "--files", scripts.FullName, "--output", Path.Combine(root.FullName, "output"), "--silent", .. arguments]);

    private static string SqliteConnectionString(string database) =>
        new SqliteConnectionStringBuilder { DataSource = database, Pooling = false }.ToString();

    private static Task<(int ExitCode, string Output, string Error)> Invoke(params string[] arguments) =>
        Invoke(arguments, []);

    internal static async Task<(int ExitCode, string Output, string Error)> Invoke(
        string[] arguments, (string Name, string Value)[] ciEnvironment)
    {
        var start = new ProcessStartInfo(Environment.GetEnvironmentVariable("DOTNET_HOST_PATH") ?? "dotnet")
        {
            UseShellExecute = false,
            RedirectStandardOutput = true,
            RedirectStandardError = true
        };
        foreach (var name in new[] { "GITHUB_ACTIONS", "TF_BUILD", "TEAMCITY_VERSION", "JENKINS_URL", "BUILD_TAG", "CI" })
        {
            start.Environment.Remove(name);
        }
        foreach (var (name, value) in ciEnvironment)
        {
            start.Environment[name] = value;
        }

        start.ArgumentList.Add(typeof(Program).Assembly.Location);
        foreach (var argument in arguments)
        {
            start.ArgumentList.Add(argument);
        }

        using var process = Process.Start(start) ?? throw new InvalidOperationException("Could not start grate CLI.");
        var output = process.StandardOutput.ReadToEndAsync();
        var error = process.StandardError.ReadToEndAsync();
        using var cancellation = CancellationTokenSource.CreateLinkedTokenSource(TestContext.Current.CancellationToken);
        cancellation.CancelAfter(TimeSpan.FromSeconds(30));
        try
        {
            await process.WaitForExitAsync(cancellation.Token);
        }
        catch (OperationCanceledException)
        {
            if (!process.HasExited) process.Kill(entireProcessTree: true);
            await process.WaitForExitAsync(CancellationToken.None);
            throw;
        }

        return (process.ExitCode, await output, await error);
    }
}
