using Microsoft.Data.Sqlite;
using TestCommon.TestInfrastructure;

namespace Sqlite.TestInfrastructure;

public sealed class SqliteTestDatabaseTests
{
    [Fact]
    public async Task Disposal_releases_pooled_connections_before_deleting_database_files()
    {
        var database = new SqliteTestDatabase();
        var connectionString = database.ConnectionString("cleanup");
        var databasePath = new SqliteConnectionStringBuilder(connectionString).DataSource;
        var directory = Directory.GetParent(databasePath);
        Assert.NotNull(directory);

        try
        {
            await using (var connection = new SqliteConnection(connectionString))
            {
                await connection.OpenAsync(TestContext.Current.CancellationToken);
                await using var command = connection.CreateCommand();
                command.CommandText = "CREATE TABLE fixture_marker (id INTEGER)";
                await command.ExecuteNonQueryAsync(TestContext.Current.CancellationToken);
            }

            await database.DisposeAsync();

            Assert.False(File.Exists(databasePath));
            await using (var connection = new SqliteConnection(connectionString))
            {
                await connection.OpenAsync(TestContext.Current.CancellationToken);
                await using var command = connection.CreateCommand();
                command.CommandText = "SELECT COUNT(*) FROM sqlite_master WHERE name = 'fixture_marker'";
                Assert.Equal(0L, await command.ExecuteScalarAsync(TestContext.Current.CancellationToken));
            }
        }
        finally
        {
            SqliteConnection.ClearAllPools();
            await database.DisposeAsync();
            directory.Delete();
        }
    }
}
