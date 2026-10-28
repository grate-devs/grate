using System.Data.Common;
using grate.Configuration;
using grate.Exceptions;
using grate.Infrastructure;
using grate.Migration;
using grate.sqlite.Infrastructure;
using grate.Sqlite.Infrastructure;
using Microsoft.Data.Sqlite;
using Microsoft.Extensions.Logging;
namespace grate.Sqlite.Migration;
public record SqliteDatabase : AnsiSqlDatabase
{
    public override string MasterDatabaseName => "master";
    public override string DatabaseType => Type;


    public SqliteDatabase(ILogger<SqliteDatabase> logger)
        : base(logger, Syntax)
    { }
    
    public static string Type => "sqlite";
    public static ISyntax Syntax { get; } = new SqliteSyntax();

    public override bool SupportsDdlTransactions => false;
    public override bool SupportsSchemas => false;
    protected override DbConnection GetSqlConnection(string? connectionString)
    {
        if (Config?.DryRun == true)
        {
            // SQLite's default ReadWriteCreate mode creates a file even when only querying migration history.
            var builder = new SqliteConnectionStringBuilder(connectionString);
            if (builder.Mode != SqliteOpenMode.Memory)
            {
                builder.Mode = SqliteOpenMode.ReadOnly;
            }
            connectionString = builder.ConnectionString;
        }
        return new SqliteConnection(connectionString);
    }

    protected override string ExistsSql(string tableSchema, string fullTableName) =>
        $@"
SELECT name FROM sqlite_master 
WHERE type ='table' AND 
LOWER(name) = LOWER('{fullTableName}');
";

    protected override string ExistsSql(string tableSchema, string fullTableName, string columnName) =>
    $@"SELECT * FROM pragma_table_info('{fullTableName}')
WHERE name='{columnName}'";

    public override string DatabaseName => GetDatabaseName(Connection);

    /// <summary>
    /// Dropping a database in Sqlite is a bit different, it's just a matter of deleting a file on disk.
    /// </summary>
    /// <returns></returns>
    public override Task DropDatabase()
    {
        var db = Connection.DataSource;

        SqliteConnection.ClearAllPools();

        if (File.Exists(db))
        {
            File.Delete(db);
        }

        return Task.CompletedTask;
    }

    public override Task<bool> DatabaseExists()
    {
        var file = Connection.DataSource;
        return Task.FromResult(File.Exists(file));
    }

    private static string GetDatabaseName(DbConnection conn) => Path.GetFileNameWithoutExtension(conn.DataSource);

    public override Task RestoreDatabase(string backupPath)
    {
        throw new System.NotImplementedException("Restoring a database from file is not currently supported for  SqlLite.");
    }

    public override void ThrowScriptFailed(MigrationsFolder folder, string file, string? scriptText, Exception exception)
    {
        throw new SqliteScriptFailed(folder, file, scriptText, exception);
    }
}
