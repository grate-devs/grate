using grate.Infrastructure;
namespace grate.Sqlite.Infrastructure;

public readonly struct SqliteSyntax : ISyntax
{
    private static readonly IStatementSplitter _statementSplitter = new SqliteStatementSplitter();
    public IStatementSplitter StatementSplitter => _statementSplitter;

    public string CurrentDatabase => "SELECT name FROM pragma_database_list ORDER BY seq DESC LIMIT 1";
    public string ListDatabases => "select name from pragma_database_list";

    // The "Create database" is a no-op with Sqlite, so we just provide a dummy SQL that just selects current DB
    public string CreateDatabase(string databaseName, string? _) => CurrentDatabase;

    // The "Drop database" is done via file deletion in Sqlite, so this isn't used.
    public string DropDatabase(string databaseName) => CurrentDatabase;

    public string TableWithSchema(string schemaName, string tableName) => $"{schemaName}_{tableName}";
    public string ReturnId => "returning id;";
    public string LimitN(string sql, int n) => sql + $"\nLIMIT {n}";
    public string ResetIdentity(string schemaName, string tableName, long _) => @$"UPDATE `sqlite_sequence`
                                                                                    SET `seq` = (SELECT MAX(`id`) FROM '{TableWithSchema(schemaName, tableName)}')
                                                                                    WHERE `name` = '{TableWithSchema(schemaName, tableName)}';";
}
