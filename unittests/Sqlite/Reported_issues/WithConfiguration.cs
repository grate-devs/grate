using Dapper;
using grate.Configuration;
using grate.Migration;
using grate.sqlite.DependencyInjection;
using Microsoft.Data.Sqlite;
using Microsoft.Extensions.DependencyInjection;

namespace Sqlite.Reported_issues;

public sealed class WithConfiguration : IDisposable
{
    private readonly string _root = Directory.CreateTempSubdirectory("grate-configuration-").FullName;

    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public async Task Changing_database_after_a_migration_isolates_connections_history_and_results(bool useBuilder)
    {
        var scripts = Directory.CreateDirectory(Path.Combine(_root, "scripts", "up"));
        await File.WriteAllTextAsync(Path.Combine(scripts.FullName, "001.sql"),
            "CREATE TABLE first_table(id INTEGER); INSERT INTO first_table VALUES (1);", TestContext.Current.CancellationToken);
        var config = new GrateConfiguration
        {
            ConnectionString = ConnectionString("a"),
            SqlFilesDirectory = scripts.Parent!,
            OutputPath = new DirectoryInfo(Path.Combine(_root, "output")),
            NonInteractive = true
        };
        await using var services = new ServiceCollection().AddLogging().AddGrateWithSqlite(config).BuildServiceProvider();
        var first = services.GetRequiredService<IGrateMigrator>();
        await first.Migrate();
        var originalHistory = await Rows("a", "SELECT * FROM grate_ScriptsRun ORDER BY id");
        var originalVersions = await Rows("a", "SELECT * FROM grate_Version ORDER BY id");

        await File.WriteAllTextAsync(Path.Combine(scripts.FullName, "002.sql"),
            "CREATE TABLE second_table(id INTEGER); INSERT INTO second_table VALUES (2);", TestContext.Current.CancellationToken);
        MigrationResult secondResult;
        string[] initialScripts;
        bool initiallyUpToDate;
        await using (var second = useBuilder
                         ? first.WithConfiguration(builder => builder.WithConnectionString(ConnectionString("b")))
                         : first.WithConfiguration(config with { ConnectionString = ConnectionString("b") }))
        {
            secondResult = Assert.IsType<GrateMigrator>(second).MigrationResult;
            initialScripts = secondResult.ScriptsRun.ToArray();
            initiallyUpToDate = secondResult.IsUpToDate;
            await second.Migrate();
        }

        Assert.Equal(new[] { "1" }, await Rows("a", "SELECT id FROM first_table"));
        Assert.Empty(await Rows("a", "SELECT name FROM sqlite_master WHERE name = 'second_table'"));
        Assert.Equal(originalHistory, await Rows("a", "SELECT * FROM grate_ScriptsRun ORDER BY id"));
        Assert.Equal(originalVersions, await Rows("a", "SELECT * FROM grate_Version ORDER BY id"));
        Assert.Equal(new[] { "1" }, await Rows("b", "SELECT id FROM first_table"));
        Assert.Equal(new[] { "2" }, await Rows("b", "SELECT id FROM second_table"));
        Assert.Equal(new[] { "001.sql", "002.sql" },
            await Rows("b", "SELECT script_name FROM grate_ScriptsRun ORDER BY id"));
        Assert.Equal(new[] { "Finished" }, await Rows("b", "SELECT status FROM grate_Version"));
        Assert.Empty(initialScripts);
        Assert.True(initiallyUpToDate);
        Assert.Equal(new[] { "001.sql", "002.sql" }, secondResult.ScriptsRun);
        Assert.Equal(new[] { "001.sql" }, Assert.IsType<GrateMigrator>(first).MigrationResult.ScriptsRun);

        // Deriving and disposing a configured copy must leave the reusable original usable.
        await using var again = first.WithConfiguration(config with { ConnectionString = ConnectionString("b") });
        await again.Migrate();
        Assert.Empty(Assert.IsType<GrateMigrator>(again).MigrationResult.ScriptsRun);
        Assert.True(Assert.IsType<GrateMigrator>(again).MigrationResult.IsUpToDate);
    }

    [Fact]
    public async Task Configured_copies_do_not_inherit_cached_history_or_flush_another_migrators_deferred_writes()
    {
        var scripts = Directory.CreateDirectory(Path.Combine(_root, "scripts", "up"));
        await File.WriteAllTextAsync(Path.Combine(scripts.FullName, "001.sql"),
            "CREATE TABLE first_table(id INTEGER);", TestContext.Current.CancellationToken);
        var config = new GrateConfiguration
        {
            ConnectionString = ConnectionString("a"),
            SqlFilesDirectory = scripts.Parent!,
            OutputPath = new DirectoryInfo(Path.Combine(_root, "output")),
            NonInteractive = true
        };
        await using var services = new ServiceCollection().AddLogging().AddGrateWithSqlite(config).BuildServiceProvider();
        var original = services.GetRequiredService<IGrateMigrator>();
        await original.Migrate();

        await File.WriteAllTextAsync(Path.Combine(scripts.FullName, "002.sql"),
            "CREATE TABLE second_table(id INTEGER);", TestContext.Current.CancellationToken);
        await using var deferred = original.WithConfiguration(config with { DeferWritingToRunTables = true });
        await deferred.Migrate();
        Assert.Equal(new[] { "002.sql" }, Assert.IsType<GrateMigrator>(deferred).MigrationResult.ScriptsRun);
        Assert.Equal(new[] { "001.sql" }, await Rows("a", "SELECT script_name FROM grate_ScriptsRun ORDER BY id"));

        await using (var other = deferred.WithConfiguration(config with { ConnectionString = ConnectionString("b") }))
        {
            await other.Migrate();
            Assert.Equal(new[] { "001.sql", "002.sql" }, Assert.IsType<GrateMigrator>(other).MigrationResult.ScriptsRun);
        }

        Assert.Equal(new[] { "001.sql", "002.sql" }, await Rows("b", "SELECT script_name FROM grate_ScriptsRun ORDER BY id"));
        Assert.Equal(new[] { "001.sql" }, await Rows("a", "SELECT script_name FROM grate_ScriptsRun ORDER BY id"));
        await deferred.DisposeAsync();
        Assert.Equal(new[] { "001.sql", "002.sql" }, await Rows("a", "SELECT script_name FROM grate_ScriptsRun ORDER BY id"));
    }

    private string ConnectionString(string database) => new SqliteConnectionStringBuilder
    {
        DataSource = Path.Combine(_root, database + ".db"), Pooling = false
    }.ToString();

    private async Task<string[]> Rows(string database, string sql)
    {
        await using var connection = new SqliteConnection(ConnectionString(database));
        var rows = await connection.QueryAsync(sql);
        return rows.Select(row => string.Join("|", ((IDictionary<string, object>)row).Values)).ToArray();
    }

    public void Dispose() => Directory.Delete(_root, recursive: true);
}
