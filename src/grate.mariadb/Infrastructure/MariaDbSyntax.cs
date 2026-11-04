using grate.Infrastructure;
namespace grate.MariaDb.Infrastructure;

public readonly struct MariaDbSyntax : ISyntax
{
    private static readonly IStatementSplitter _statementSplitter = new MariaDbStatementSplitter();
    public IStatementSplitter StatementSplitter => _statementSplitter;

    public string CurrentDatabase => "SELECT DATABASE()";
    public string ListDatabases => "SHOW DATABASES";
    public string CreateDatabase(string databaseName, string? _) => @$"CREATE DATABASE {databaseName}";
    public string DropDatabase(string databaseName) => @$"DROP DATABASE IF EXISTS `{databaseName}`;";
    public string TableWithSchema(string schemaName, string tableName) => $"{schemaName}_{tableName}";
    public string ReturnId => ";SELECT LAST_INSERT_ID();";
    public string LimitN(string sql, int n) => sql + "\nLIMIT 1";

    // any idea to reset identity without using value is welcome.
    public string ResetIdentity(string schemaName, string tableName, long value) => @$"ALTER TABLE {TableWithSchema(schemaName, tableName)} AUTO_INCREMENT = {value}";
}
