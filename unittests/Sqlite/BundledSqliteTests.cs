using Microsoft.Data.Sqlite;

namespace Sqlite;

public sealed class BundledSqliteTests(ITestOutputHelper output)
{
    [Fact]
    public void Native_sqlite_includes_the_FTS5_security_fix_and_supports_full_text_search()
    {
        using var connection = new SqliteConnection("Data Source=:memory:");
        connection.Open();
        output.WriteLine($"Loaded native SQLite {connection.ServerVersion}");

        // SQLite identifies 3.53.2 as the fix for CVE-2026-11822 / CVE-2026-11824.
        Assert.True(Version.Parse(connection.ServerVersion) >= new Version(3, 53, 2),
            $"Native SQLite {connection.ServerVersion} predates the FTS5 security fix.");

        using var command = connection.CreateCommand();
        command.CommandText = "SELECT sqlite_compileoption_used('ENABLE_FTS5')";
        Assert.Equal(1L, command.ExecuteScalar());
        command.CommandText = """
            CREATE VIRTUAL TABLE documents USING fts5(body);
            INSERT INTO documents(body) VALUES ('grate database migrations');
            SELECT body FROM documents WHERE documents MATCH 'migrations';
            """;
        Assert.Equal("grate database migrations", command.ExecuteScalar());
    }
}
