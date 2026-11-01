using grate.Infrastructure;
namespace grate.PostgreSql.Infrastructure;

public readonly struct PostgreSqlSyntax : ISyntax
{
    private static readonly IStatementSplitter _statementSplitter = new PostgreSqlStatementSplitter();
    public IStatementSplitter StatementSplitter => _statementSplitter;

    public string CurrentDatabase => "SELECT current_database()";
    public string ListDatabases => "SELECT datname FROM pg_database";
    public string CreateDatabase(string databaseName, string? _) => @$"CREATE DATABASE ""{databaseName}""";
    public string DropDatabase(string databaseName) => @$"select pg_terminate_backend(pid) from pg_stat_activity where datname='{databaseName}';
                                                              COMMIT;
                                                              DROP DATABASE IF EXISTS ""{databaseName}"";";
    public string TableWithSchema(string schemaName, string tableName) => $"\"{schemaName}\".\"{tableName}\"";
    public string ReturnId => "RETURNING id;";
    public string LimitN(string sql, int n) => sql + $"\nLIMIT {n}";
    public string ResetIdentity(string schemaName, string tableName, long _) => @$"SELECT setval(pg_get_serial_sequence('{TableWithSchema(schemaName, tableName)}', 'id'), coalesce(MAX(id), 1)) from {TableWithSchema(schemaName, tableName)};";
}
