using System.Data.Common;
using System.Diagnostics;
using grate.Configuration;
using grate.Exceptions;
using grate.Infrastructure;
using grate.MariaDb.Infrastructure;
using grate.Migration;
using Microsoft.Extensions.Logging;
using MySqlConnector;
namespace grate.MariaDb.Migration;

public record MariaDbDatabase : AnsiSqlDatabase
{
    public override string MasterDatabaseName => "mysql";
    public override string DatabaseType => Type;
    public MariaDbDatabase(ILogger<MariaDbDatabase> logger)
        : base(logger, Syntax)
    { }

    public override bool SupportsDdlTransactions => false;
    public override bool SupportsSchemas => false;

    public static string Type => "mariadb";
    public static ISyntax Syntax { get; } = new MariaDbSyntax();


    protected override DbConnection GetSqlConnection(string? connectionString)
    {
        //if we actually get a null here we're in trouble, but the cascading changes of making the param
        //non-null are significant.
        connectionString ??= "";

        // If pipelining is not explicitly mentioned in the connection string, turn it off, as enabling it
        // might lead to problems in more scenarios than it (potentially) solves, in the most
        // common grate scenarios.
        if (!connectionString.Contains("Pipelining", StringComparison.InvariantCultureIgnoreCase))
        {
            var builder = new MySqlConnectionStringBuilder(connectionString) { Pipelining = false };
            connectionString = builder.ConnectionString;
        }

        var conn = new MySqlConnection(connectionString);
        return conn;
    }

    public override Task RestoreDatabase(string backupPath)
    {
        throw new System.NotImplementedException("Restoring a database from file is not currently supported for Maria DB.");
    }

    public override async Task DropDatabase()
    {
        // Drop the database in normal fashion
        await base.DropDatabase();

        // We need to kill any active connections to get MariaDB to actually delete the database,
        // and stop accepting new connections to it. So we create a list of the
        // active sessions against our database, and create 'KILL X' statements (where X is session id).
        // Then we execute the kill statements.
        var sql = $@"
SELECT GROUP_CONCAT(CONCAT('KILL ',id,';') SEPARATOR ' ')
FROM information_schema.processlist WHERE DB = '{DatabaseName}'";

        var killStatements = await ExecuteStringScalarAsync(AdminConnection, sql);
        if (killStatements != null)
        {
            await ExecuteNonQuery(AdminConnection, killStatements, null);
        }

        var databaseExists = await DatabaseExists();
        Debug.Assert(!databaseExists, "Database still exists after it is dropped");
    }

    public override void ThrowScriptFailed(MigrationsFolder folder, string file, string? scriptText, Exception exception)
    {
        throw new MariaDbScriptFailed(folder, file, scriptText, exception);
    }
}
