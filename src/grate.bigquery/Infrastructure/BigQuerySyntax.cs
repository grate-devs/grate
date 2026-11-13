using grate.Infrastructure;

namespace grate.BigQuery.Infrastructure;

/// <summary>
/// BigQuery's dialect. A dataset is the database, and a dataset holds tables but no schemas, so grate's tables are
/// named <c>{schema}_{table}</c> inside the target dataset, as with SQLite.
/// </summary>
public readonly struct BigQuerySyntax : ISyntax
{
    private static readonly IStatementSplitter _statementSplitter = new BigQueryStatementSplitter();
    public IStatementSplitter StatementSplitter => _statementSplitter;

    public string CurrentDatabase => "SELECT @@dataset_id";
    public string ListDatabases => "SELECT schema_name FROM INFORMATION_SCHEMA.SCHEMATA";
    public string CreateDatabase(string databaseName, string? _) => $"CREATE SCHEMA IF NOT EXISTS `{databaseName}`";
    public string DropDatabase(string databaseName) => $"DROP SCHEMA IF EXISTS `{databaseName}` CASCADE";
    public string TableWithSchema(string schemaName, string tableName) => $"{schemaName}_{tableName}";
    public string LimitN(string sql, int n) => sql + $"\nLIMIT {n}";

    // BigQuery has no identity columns - the provider gives each row an id itself
    public string ReturnId => string.Empty;
    public string ResetIdentity(string schemaName, string tableName, long value) => string.Empty;
}
