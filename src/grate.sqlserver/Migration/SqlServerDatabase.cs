using System.Data;
using System.Data.Common;
using System.Transactions;
using grate.Configuration;
using grate.Exceptions;
using grate.Infrastructure;
using grate.Migration;
using grate.sqlserver.Infrastructure;
using grate.SqlServer.Infrastructure;
using Microsoft.Data.SqlClient;
using Microsoft.Extensions.Logging;
namespace grate.SqlServer.Migration;
public record SqlServerDatabase : AnsiSqlDatabase
{
    public override string MasterDatabaseName => "master";
    public override string DatabaseType => Type;
    public SqlServerDatabase(ILogger<SqlServerDatabase> logger)
        : base(logger, Syntax)
    { }
    
    public static string Type => "sqlserver";
    public static ISyntax Syntax { get; } = new SqlServerSyntax();

    public override bool SupportsDdlTransactions => true;
    public override bool SupportsSchemas => true;
    protected override DbConnection GetSqlConnection(string? connectionString)
    {
        // If pooling is not explicitly mentioned in the connection string, turn it off, as enabling it
        // might lead to problems in more scenarios than it (potentially) solves, in the most
        // common grate scenarios.
        // if (!(connectionString ?? "").Contains("Pooling", StringComparison.InvariantCultureIgnoreCase))
        // {
        //     var builder = new SqlConnectionStringBuilder(connectionString) { Pooling = false };
        //     connectionString = builder.ConnectionString;
        // }
        //
        var conn = new SqlConnection(connectionString)
        {
            AccessToken = AccessToken
        };
        return conn;
    }
    protected override async Task ExecuteScriptBatch(DbConnection connection, string sql, int? timeout, string? scriptName)
    {
        var logger = Logger;
        if (connection is not SqlConnection sqlConnection || !logger.IsEnabled(LogLevel.Debug))
        {
            await base.ExecuteScriptBatch(connection, sql, timeout, scriptName);
            return;
        }

        void LogInfoMessage(object sender, SqlInfoMessageEventArgs args)
        {
            foreach (SqlError message in args.Errors)
            {
                if (scriptName is null)
                {
                    logger.LogDebug("SQL Server: {Message}", message.Message);
                }
                else
                {
                    logger.LogDebug("SQL Server ({ScriptName}): {Message}", scriptName, message.Message);
                }
            }
        }

        // Leave FireInfoMessageEventOnUserErrors at its default so SQL errors still throw.
        sqlConnection.InfoMessage += LogInfoMessage;
        try
        {
            await base.ExecuteScriptBatch(connection, sql, timeout, scriptName);
        }
        finally
        {
            sqlConnection.InfoMessage -= LogInfoMessage;
        }
    }

    protected string? AccessToken { get; private set; }

    public override Task InitializeConnections(GrateConfiguration configuration)
    {
        AccessToken = configuration.AccessToken;
        return base.InitializeConnections(configuration);
    }
    
    // Needs admin connection, which we do not always have.
    // Could we use the optimization _if_ we have an admin connection, and turn it off if we don't?
    
    // public override async Task<bool> DatabaseExists()
    // {
    //     var sql = @$"USE master;
    //                 SELECT 1 FROM sys.databases WHERE [name] = @dbname";
    //     try
    //     {
    //
    //         Logger.LogInformation("Trying to check the database {DbName} database on {Server}", DatabaseName, ServerName);
    //         await OpenAdminConnection();
    //         var cmd = AdminConnection.CreateCommand();
    //         cmd.CommandText = sql;
    //
    //         // dbName parameter
    //         var dbNameParam = cmd.CreateParameter();
    //         dbNameParam.ParameterName = "@dbname";
    //         dbNameParam.Value = DatabaseName;
    //         cmd.Parameters.Add(dbNameParam);
    //         var result = await cmd.ExecuteScalarAsync();
    //         Logger.LogInformation("Database {DbName} querying with result {Result}", DatabaseName, result);
    //         return result is not null;
    //
    //     }
    //     catch (DbException e)
    //     {
    //         Logger.LogDebug(e, "Got error: {ErrorMessage}", e.Message);
    //         return false;
    //     }
    //
    // }
    public override async Task RestoreDatabase(string backupPath)
    {
        var databaseName = DatabaseName;
        // ALTER DATABASE requires an identifier. QuoteIdentifier doubles any closing bracket in the name.
        using var commandBuilder = new SqlCommandBuilder { QuotePrefix = "[", QuoteSuffix = "]" };
        var quotedDatabaseName = commandBuilder.QuoteIdentifier(databaseName);

        // RESTORE accepts parameters for the database and backup path, but MOVE requires string literals.
        var moveClauses = string.Concat((Config?.RestoreMoves ?? []).Select(move =>
            $", MOVE {QuoteRestoreLiteral(move.LogicalName)} TO {QuoteRestoreLiteral(move.DestinationPath)}"));

        using (new TransactionScope(TransactionScopeOption.Suppress, TransactionScopeAsyncFlowOption.Enabled))
        {
            var restoreStarted = false;
            try
            {
                await OpenAdminConnection();
                Logger.LogInformation("Restoring {DbName} database on {Server} server from path {Path}.", DatabaseName, ServerName, backupPath);
                await using var cmd = AdminConnection.CreateCommand();
                cmd.CommandText =
                    $"""
                    USE [master];
                    ALTER DATABASE {quotedDatabaseName} SET SINGLE_USER WITH ROLLBACK IMMEDIATE;
                    RESTORE DATABASE @databaseName
                    FROM DISK = @backupPath
                    WITH NOUNLOAD, STATS = 10, RECOVERY, REPLACE{moveClauses};
                    """;
                AddParameter(cmd, "@databaseName", databaseName);
                AddParameter(cmd, "@backupPath", backupPath);
                restoreStarted = true;
                await cmd.ExecuteNonQueryAsync();
                await ExecuteNonQuery(AdminConnection,
                    $"USE [master]; ALTER DATABASE {quotedDatabaseName} SET MULTI_USER WITH ROLLBACK IMMEDIATE;", timeout: null);
            }
            catch (Exception ex)
            {
                Logger.LogDebug(ex, "Got error: {ErrorMessage}", ex.Message);
                if (restoreStarted)
                {
                    await RestoreMultiUserAccess(databaseName, quotedDatabaseName);
                }

                throw;
            }
            finally
            {
                await CloseAdminConnection();
            }
        }

        await WaitUntilDatabaseIsReady();

        Logger.LogInformation("Database {DbName} successfully restored from path {Path}.", DatabaseName, backupPath);
    }

    private async Task RestoreMultiUserAccess(string databaseName, string quotedDatabaseName)
    {
        try
        {
            if (AdminConnection.State != ConnectionState.Open)
            {
                await CloseAdminConnection();
                await OpenAdminConnection();
            }

            await using var cmd = AdminConnection.CreateCommand();
            cmd.CommandText =
                $"""
                USE [master];
                IF EXISTS (SELECT 1 FROM sys.databases WHERE name = @databaseName AND user_access = 1)
                    ALTER DATABASE {quotedDatabaseName} SET MULTI_USER WITH ROLLBACK IMMEDIATE;
                """;
            AddParameter(cmd, "@databaseName", databaseName);
            await cmd.ExecuteNonQueryAsync();
        }
        catch (Exception ex)
        {
            Logger.LogWarning(ex, "Could not return database {DbName} to MULTI_USER after restore failed.", DatabaseName);
        }
    }

    private static string QuoteRestoreLiteral(string value) => $"N'{value.Replace("'", "''", StringComparison.Ordinal)}'";

    private static void AddParameter(DbCommand command, string name, string value)
    {
        var parameter = command.CreateParameter();
        parameter.ParameterName = name;
        parameter.Value = value;
        command.Parameters.Add(parameter);
    }

    protected override string HasRunSql =>
        $@"
SELECT 1 FROM  {ScriptsRunTable} WITH (NOLOCK)
WHERE script_name = @scriptName";


    public override void ThrowScriptFailed(MigrationsFolder folder, string file, string? scriptText, Exception exception)
    {
        throw new SqlServerScriptFailed(folder, file, scriptText, exception);
    }
}
