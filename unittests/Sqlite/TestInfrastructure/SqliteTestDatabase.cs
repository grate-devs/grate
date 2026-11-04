using Microsoft.Data.Sqlite;
using Dir = System.IO.Directory;

namespace TestCommon.TestInfrastructure;

// ReSharper disable once ClassNeverInstantiated.Global
public class SqliteTestDatabase : ITestDatabase, IAsyncLifetime
{
    private readonly string _root = Dir.CreateTempSubdirectory("grate-sqlite-tests-").ToString();

    public ValueTask DisposeAsync()
    {
        // Pooled connections keep database files open on Windows.
        SqliteConnection.ClearAllPools();

        var dbFiles = Directory.GetFiles(_root, "*.db");
        foreach (var dbFile in dbFiles)
        {
            File.Delete(dbFile);
        }
        return ValueTask.CompletedTask;
    }

    public ValueTask InitializeAsync()
    {
        return ValueTask.CompletedTask;
    }

    public string AdminConnectionString => $"Data Source={Wrap("grate-sqlite.db")}";
    public string ConnectionString(string database) => $"Data Source={Wrap(database + ".db")}";
    public string UserConnectionString(string database) => $"Data Source={Wrap(database + ".db")}";

    private string Wrap(string database)
    {
        return Path.Combine(_root, database);
    }
}
