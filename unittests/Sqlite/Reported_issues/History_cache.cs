using grate.Configuration;
using grate.Migration;
using grate.Sqlite.Migration;
using Microsoft.Data.Sqlite;
using Microsoft.Extensions.Logging.Abstractions;

namespace Sqlite.Reported_issues;

public sealed class History_cache
{
    [Fact]
    public async Task A_failed_history_write_is_not_cached_as_successful_and_can_be_retried()
    {
        await using var database = new SqliteDatabase(NullLogger<SqliteDatabase>.Instance);
        await database.InitializeConnections(new GrateConfiguration { ConnectionString = "Data Source=:memory:" });
        await database.OpenConnection();
        await database.RunSql($"CREATE TABLE {database.ScriptsRunTable} (id INTEGER PRIMARY KEY, version_id INTEGER, script_name TEXT, text_of_script TEXT, text_hash TEXT, one_time_script INTEGER, entry_date TEXT, modified_date TEXT, entered_by TEXT)", ConnectionType.Default, TransactionHandling.Default);
        await database.RunSql($"CREATE TRIGGER fail_history BEFORE INSERT ON {database.ScriptsRunTable} BEGIN SELECT RAISE(ABORT, 'Expected history failure'); END;", ConnectionType.Default, TransactionHandling.Default);
        Assert.False(await database.HasRun("001.sql", TransactionHandling.Default));

        var failure = await Assert.ThrowsAsync<SqliteException>(() =>
            database.InsertScriptRun("001.sql", "SELECT 1", "hash", true, 1, TransactionHandling.Default));

        Assert.Contains("Expected history failure", failure.Message);
        Assert.False(await database.HasRun("001.sql", TransactionHandling.Default));
        Assert.Null(await database.GetCurrentHash("001.sql"));

        await database.RunSql("DROP TRIGGER fail_history;", ConnectionType.Default, TransactionHandling.Default);
        await database.InsertScriptRun("001.sql", "SELECT 1", "hash", true, 1, TransactionHandling.Default);

        Assert.True(await database.HasRun("001.sql", TransactionHandling.Default));
        Assert.Equal("hash", await database.GetCurrentHash("001.sql"));
    }
}
