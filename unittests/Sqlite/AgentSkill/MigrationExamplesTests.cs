using System.Diagnostics;
using System.Globalization;
using Microsoft.Data.Sqlite;

namespace Sqlite.AgentSkill;

// This is an integration check of the shipped SQL assets, not an evaluation of agent behavior.
public sealed class MigrationExamplesTests(ITestOutputHelper output) : IDisposable
{
    private readonly string _root = Directory.CreateTempSubdirectory("grate-example-tests-").FullName;

    [Fact]
    public async Task Bundled_sqlite_example_creates_the_documented_schema_and_data_and_can_be_rerun()
    {
        var scripts = Path.Combine(AppContext.BaseDirectory, "AgentSkill", "Fixtures", "sqlite-example");
        var database = Path.Combine(_root, "example.sqlite");
        await Migrate(scripts, database);

        Assert.Equal(new[] { "1", "W-001", "Starter widget" }, Assert.Single(Rows(database,
            "SELECT id, code, name FROM widgets")));
        Assert.Contains(Rows(database, "PRAGMA index_list('widgets')"), row => row[1] == "ux_widgets_code" && row[2] == "1");
        Assert.Equal(new[] { "code" }, Rows(database, "PRAGMA index_info('ux_widgets_code')").Select(row => row[2]));
        var history = Rows(database, "SELECT script_name, text_hash, one_time_script FROM grate_ScriptsRun ORDER BY id");
        Assert.Equal(new[] { "001_create_widgets.sql", "002_create_widgets_code_index.sql", "003_seed_widget.sql" },
            history.Select(row => row[0]));
        Assert.All(history, row => { Assert.NotEmpty(row[1]); Assert.Equal("1", row[2]); });

        await Migrate(scripts, database);

        Assert.Equal(new[] { "1", "W-001", "Starter widget" }, Assert.Single(Rows(database,
            "SELECT id, code, name FROM widgets")));
        Assert.Equal(history, Rows(database, "SELECT script_name, text_hash, one_time_script FROM grate_ScriptsRun ORDER BY id"));
    }

    private async Task Migrate(string scripts, string database)
    {
        var start = new ProcessStartInfo(Environment.GetEnvironmentVariable("DOTNET_HOST_PATH") ?? "dotnet")
        {
            WorkingDirectory = _root, UseShellExecute = false,
            RedirectStandardInput = true, RedirectStandardOutput = true, RedirectStandardError = true
        };
        foreach (var argument in new[]
        {
            typeof(grate.Program).Assembly.Location, "--databasetype=SQLite",
            $"--connectionstring={new SqliteConnectionStringBuilder { DataSource = database, Pooling = false }}",
            $"--sqlfilesdirectory={scripts}", $"--outputPath={Path.Combine(_root, "output")}", "--silent"
        }) start.ArgumentList.Add(argument);
        using var process = Process.Start(start) ?? throw new InvalidOperationException("Could not start built grate CLI.");
        process.StandardInput.Close();
        var stdout = process.StandardOutput.ReadToEndAsync();
        var stderr = process.StandardError.ReadToEndAsync();
        using var cancellation = CancellationTokenSource.CreateLinkedTokenSource(TestContext.Current.CancellationToken);
        cancellation.CancelAfter(TimeSpan.FromSeconds(60));
        try
        {
            await process.WaitForExitAsync(cancellation.Token);
        }
        catch (OperationCanceledException)
        {
            if (!process.HasExited) process.Kill(entireProcessTree: true);
            await process.WaitForExitAsync(CancellationToken.None);
            TestContext.Current.CancellationToken.ThrowIfCancellationRequested();
            throw new TimeoutException("Example migration exceeded 60 seconds.");
        }
        output.WriteLine(await stdout + await stderr);
        Assert.Equal(0, process.ExitCode);
    }

    private static List<string[]> Rows(string database, string sql)
    {
        using var connection = new SqliteConnection(new SqliteConnectionStringBuilder
            { DataSource = database, Mode = SqliteOpenMode.ReadOnly, Pooling = false }.ToString());
        connection.Open();
        using var command = connection.CreateCommand();
        command.CommandText = sql;
        using var reader = command.ExecuteReader();
        var rows = new List<string[]>();
        while (reader.Read()) rows.Add(Enumerable.Range(0, reader.FieldCount)
            .Select(index => Convert.ToString(reader.GetValue(index), CultureInfo.InvariantCulture) ?? "").ToArray());
        return rows;
    }

    public void Dispose() => Directory.Delete(_root, recursive: true);
}
