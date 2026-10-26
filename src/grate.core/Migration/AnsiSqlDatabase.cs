using System.Data;
using System.Data.Common;
using System.Security.Claims;
using System.Transactions;
using Dapper;
using grate.Configuration;
using grate.Exceptions;
using grate.Infrastructure;
using Microsoft.Extensions.Logging;
using static System.StringSplitOptions;
using IsolationLevel = System.Transactions.IsolationLevel;

namespace grate.Migration;

public abstract record AnsiSqlDatabase : IDatabase
{
    private const string Now = "now";
    private const string User = "usr";

    private string SchemaName { get; set; } = "";

    protected GrateConfiguration? Config { get; private set; }

    protected ILogger Logger { get; private set; }
    private DbConnection? _connection;
    private DbConnection? _adminConnection;
    private readonly ISyntax _syntax;

    public void SetLogger(ILogger logger) => Logger = logger;

    private IDictionary<string, string>? _scriptsRunCache;
    
    private readonly List<Func<DbConnection, Task>> _deferredWrites = new();

    protected AnsiSqlDatabase(ILogger logger, ISyntax syntax)
    {
        Logger = logger;
        _syntax = syntax;
    }
    
    public string ServerName => Connection.DataSource;
    public virtual string DatabaseName => Connection.Database;
    public abstract string MasterDatabaseName { get; }
    public abstract string DatabaseType { get; }

    private string? Password => ConnectionString?.Split(";", TrimEntries | RemoveEmptyEntries)
        .SingleOrDefault(entry => 
            entry.StartsWith("Password", StringComparison.OrdinalIgnoreCase) || 
            entry.StartsWith("Pwd", StringComparison.OrdinalIgnoreCase))?
        .Split("=", TrimEntries | RemoveEmptyEntries).Last();

    public abstract bool SupportsDdlTransactions { get; }
    public abstract bool SupportsSchemas { get; }

    public virtual bool SplitBatchStatements => true;
    private IStatementSplitter StatementSplitter => _syntax.StatementSplitter;

    public virtual IEnumerable<string> GetStatements(string sql)
        => SplitBatchStatements ? this.StatementSplitter.Split(sql) : new[] { sql };

    public abstract void ThrowScriptFailed(MigrationsFolder folder, string file, string? scriptText, Exception exception);

    public string ScriptsRunTable => _syntax.TableWithSchema(SchemaName, ScriptsRunTableName);
    public string ScriptsRunErrorsTable => _syntax.TableWithSchema(SchemaName, ScriptsRunErrorsTableName);
    public string VersionTable => _syntax.TableWithSchema(SchemaName, VersionTableName);

    private string ScriptsRunTableName { get; set; } = "";
    private string ScriptsRunErrorsTableName { get; set; } = "";
    private string VersionTableName { get; set; } = "";

    public virtual Task InitializeConnections(GrateConfiguration configuration)
    {
        Logger.LogInformation("Initializing connections.");

        ConnectionString = configuration.ConnectionString;
        AdminConnectionString = this.GetAdminConnectionString(configuration);

        SchemaName = configuration.SchemaName;

        VersionTableName = configuration.VersionTableName;
        ScriptsRunTableName = configuration.ScriptsRunTableName;
        ScriptsRunErrorsTableName = configuration.ScriptsRunErrorsTableName;

        Config = configuration;

        return Task.CompletedTask;
    }

    private async Task<string> ExistingOrDefault(string schemaName, string tableName) =>
        await ExistingTable(schemaName, tableName) ?? tableName;


    private string? AdminConnectionString { get; set; }
    protected string? ConnectionString { get; set; }

    protected abstract DbConnection GetSqlConnection(string? connectionString);

    protected DbConnection AdminConnection => _adminConnection ??= GetSqlConnection(AdminConnectionString);

    protected DbConnection Connection => _connection ??= GetSqlConnection(ConnectionString);

    public DbConnection ActiveConnection { protected get; set; } = default!;

    public void SetDefaultConnectionActive()
    {
        ActiveConnection = Connection;
    }

    private class NewActiveConnectionWrapper : IDisposable
    {
        private readonly IDbConnection _conn;
        private readonly IDatabase _owner;

        public NewActiveConnectionWrapper(IDbConnection conn, IDatabase owner)
        {
            _conn = conn;
            _owner = owner;
        }

        public void Dispose()
        {
            _conn.Close();
            _conn.Dispose();
            _owner.SetDefaultConnectionActive();
        }
    }

    public async Task<IDisposable> OpenNewActiveConnection()
    {
        var newConnection = GetSqlConnection(ConnectionString);
        await Open(newConnection);
        ActiveConnection = newConnection;
        return new NewActiveConnectionWrapper(ActiveConnection, this);
    }

    protected async Task<TResult> RunInAutonomousTransaction<TResult>(string? connectionString, Func<DbConnection, Task<TResult>> func)
    {
        TResult res;
        using (var s = new TransactionScope(
                   TransactionScopeOption.Suppress,
                   new TransactionOptions() { IsolationLevel = IsolationLevel.ReadUncommitted },
                   TransactionScopeAsyncFlowOption.Enabled))
        {
            await using (var connection = GetSqlConnection(connectionString))
            {
                await Open(connection);
                res = await func(connection);
                await Close(connection);
            }
            s.Complete();
        }
        return res;
    }

    protected async Task RunInAutonomousTransaction(string? connectionString, Func<DbConnection, Task> func)
    {
        using var s = new TransactionScope(TransactionScopeOption.Suppress, TransactionScopeAsyncFlowOption.Enabled);
        await using (var connection = GetSqlConnection(connectionString))
        {
            await Open(connection);
            await func(connection);
            await Close(connection);
        }
        s.Complete();
    }

    public async Task OpenActiveConnection()
    {
        await Open(ActiveConnection);
    }

    public async Task OpenConnection()
    {
        await Open(Connection);
        SetDefaultConnectionActive();
    }

    // Don't use the properties, they can open a connection just to dispose it!
    public async Task CloseConnection()
    {
        await Close(_connection);
        _connection = null;
    }

    public async Task OpenAdminConnection() => await Open(AdminConnection);
    // Don't use the properties, they can open a connection just to dispose it!
    public async Task CloseAdminConnection()
    {
        await Close(_adminConnection);
        _adminConnection = null;
    }

    public async Task CreateDatabase()
    {
        if (!await DatabaseExists())
        {
            Logger.LogTrace("Creating database {DatabaseName}", DatabaseName);

            await OpenAdminConnection();

            var sql = _syntax.CreateDatabase(DatabaseName, Password);
            await ExecuteNonQuery(AdminConnection, sql, Config?.AdminCommandTimeout);
        }

        await CloseAdminConnection();
        await WaitUntilDatabaseIsReady();
    }

    public virtual async Task DropDatabase()
    {
        if (await DatabaseExists())
        {
            await CloseConnection(); // try and ensure there's nobody else in there...
            await OpenAdminConnection();
            await ExecuteNonQuery(AdminConnection, _syntax.DropDatabase(DatabaseName), Config?.AdminCommandTimeout);
        }
    }


    /// <summary>
    /// Gets whether the Database currently exists on the server or not.
    /// </summary>
    /// <returns></returns>
    public virtual async Task<bool> DatabaseExists()
    {
        try
        {
            await OpenActiveConnection();
            return true;
        }
        catch (DbException e)
        {
            Logger.LogDebug(e, "DatabaseExists: Error connecting to database {DatabaseName}. Database probably doesn't exist. Error message: {ErrorMessage}", DatabaseName, e.Message);
            return false;
        }
    }

    protected async Task WaitUntilDatabaseIsReady()
    {
        const int maxDelay = 10_000;
        int totalDelay = 0;

        var databaseReady = false;
        do
        {
            try
            {
                using var s = new TransactionScope(TransactionScopeOption.Suppress, TransactionScopeAsyncFlowOption.Enabled);
                using (await OpenNewActiveConnection())
                {
                    databaseReady = true;
                }
                s.Complete();
            }
            catch (DbException)
            {
                await Task.Delay(1000);
                totalDelay += 1000;
            }
        } while (!databaseReady && totalDelay < maxDelay);
    }

    public async Task<bool> VersionTableExists() => (await ExistingTable(SchemaName, VersionTableName) is not null);

    public async Task<string?> ExistingTable(string schemaName, string tableName)
    {
        var fullTableName = SupportsSchemas ? tableName : _syntax.TableWithSchema(schemaName, tableName);
        var tableSchema = SupportsSchemas ? schemaName : DatabaseName;

        string existsSql = ExistsSql(tableSchema, fullTableName);

        var res = await ExecuteScalarAsync<object>(ActiveConnection, existsSql);

        var name = (!DBNull.Value.Equals(res) && res is not null) ? (string)res : null;

        var prefix = SupportsSchemas ? string.Empty : _syntax.TableWithSchema(schemaName, string.Empty);
        return name?[prefix.Length..];
    }
   
    public async Task<bool> GrateInternalTablesAreProperlyLogged()
    {
        const string tableName = "GrateScriptsRun";

        string existsSql = $"SELECT 1 FROM {_syntax.TableWithSchema(SchemaName, tableName)} WHERE script_name = '02_create_scripts_run_table.sql'";

        if (await ExistingTable(SchemaName, tableName) is { })
        {
            var res = await ExecuteScalarAsync<int?>(ActiveConnection, existsSql);
            return res is 1;
        }
        return false;
    }
    

    protected virtual string ExistsSql(string tableSchema, string fullTableName)
    {
        return $@"
SELECT table_name FROM INFORMATION_SCHEMA.TABLES 
WHERE 
LOWER(TABLE_SCHEMA) = LOWER('{tableSchema}') AND
LOWER(TABLE_NAME) = LOWER('{fullTableName}')
";
    }

    protected virtual string ExistsSql(string tableSchema, string fullTableName, string columnName)
    {
        return $@"
SELECT * FROM INFORMATION_SCHEMA.COLUMNS 
WHERE 
LOWER(TABLE_SCHEMA) = LOWER('{tableSchema}') AND
LOWER(TABLE_NAME) = LOWER('{fullTableName}') AND
LOWER(COLUMN_NAME) = LOWER('{columnName}') 
";
    }

    protected virtual string CurrentVersionSql => $@"
SELECT 
{_syntax.LimitN($@"
version
FROM {VersionTable}
ORDER BY id DESC", 1)}
";
    public const string NotVersioning = "0.0.0.0";
    public async Task<string> GetCurrentVersion()
    {
        try
        {
            var sql = CurrentVersionSql;
            var res = await ExecuteScalarAsync<string>(ActiveConnection, sql);
            return res ?? NotVersioning;
        }
        catch (Exception ex)
        {
            Logger.LogDebug(ex, "An error occurred getting the current database version, new database + --dryrun?");
            return NotVersioning;
        }
    }

    public virtual async Task<long> VersionTheDatabase(string newVersion)
    {
        var sql = Parameterize($@"
INSERT INTO {VersionTable}
(repository_path, version, entry_date, modified_date, entered_by, status)
VALUES(@repositoryPath, @newVersion, @entryDate, @modifiedDate, @enteredBy, @status)

{_syntax.ReturnId}
");
        var repositoryPath = Config?.RepositoryPath;

        long versionId;

        try
        {
            versionId = (long) await ActiveConnection.ExecuteScalarAsync<int>(
                sql,
                new
                {
                    repositoryPath,
                    newVersion,
                    entryDate = DateTime.UtcNow,
                    modifiedDate = DateTime.UtcNow,
                    enteredBy = GetUserName(),
                    status = MigrationStatus.InProgress
                });
        } 
        catch (Exception ex)
        {
            Logger.LogDebug(ex, "Could not find version table in {DbName} database. Using default version Id", DatabaseName);
            versionId = 1;
        }

        if (repositoryPath != null)
        {
            Logger.LogInformation(" Versioning {DbName} database with version {Version} based on {RepositoryPath}.", DatabaseName, newVersion, repositoryPath);
        }
        else
        {
            Logger.LogInformation(" Versioning {DbName} database with version {Version}.", DatabaseName, newVersion);
        }

        return versionId;
    }

    protected string GetUserName()
    {
        return ClaimsPrincipal.Current?.Identity?.Name ?? Environment.UserName;
    }

    public virtual async Task ChangeVersionStatus(string status, long versionId)
    {
        var updateSql = Parameterize($@"
            UPDATE {VersionTable}
            SET status = @status
            WHERE id = @versionId");

        using var s = new TransactionScope(TransactionScopeOption.Suppress, TransactionScopeAsyncFlowOption.Enabled);
        await ExecuteAsync(Connection, updateSql, new { status, versionId });

        s.Complete();
    }
    
    public virtual async Task DeleteVersionRecord(long versionId)
    {
        var deleteSql = Parameterize($@"
            DELETE FROM {VersionTable}
            WHERE id = @versionId");

        using var s = new TransactionScope(TransactionScopeOption.Suppress, TransactionScopeAsyncFlowOption.Enabled);
        await ExecuteAsync(Connection, deleteSql, new { versionId });
        
        // reset the identity column of the table to the previous value
        await ExecuteAsync(Connection, _syntax.ResetIdentity(SchemaName, VersionTableName, versionId - 1));

        s.Complete();
    }

    public void Rollback()
    {
        Logger.LogInformation("Rolling back changes.");
        Transaction.Current?.Rollback();
    }

    public async Task RunSql(string sql, ConnectionType connectionType, TransactionHandling transactionHandling)
    {
        Logger.LogTrace("[SQL] Running (on connection '{ConnType}', transaction handling '{TransactionHandling}'): \n{Sql}",
                            connectionType.ToString(),
                            transactionHandling,
                            sql);

        int? timeout = GetTimeout(connectionType);
        var connection = GetDbConnection(connectionType);

        await Open(connection);
        await ExecuteNonQuery(connection, sql, timeout);
    }


    private DbConnection GetDbConnection(ConnectionType connectionType) =>
        connectionType switch
        {
            ConnectionType.Default => ActiveConnection,
            ConnectionType.Admin => AdminConnection,
            _ => throw new UnknownConnectionType(connectionType)
        };

    private int? GetTimeout(ConnectionType connectionType) =>
        connectionType switch
        {
            ConnectionType.Default => Config?.CommandTimeout,
            ConnectionType.Admin => Config?.AdminCommandTimeout,
            _ => throw new UnknownConnectionType(connectionType)
        };

    // ReSharper disable once ClassNeverInstantiated.Local
    private class ScriptsRunCacheItem
    {
#pragma warning disable 8618
        // ReSharper disable InconsistentNaming
        // ReSharper disable UnusedAutoPropertyAccessor.Local

        public string script_name { get; init; }
        public string text_hash { get; init; }

        // ReSharper restore InconsistentNaming
        // ReSharper restore UnusedAutoPropertyAccessor.Local
#pragma warning restore 8618
    }

    private async Task<IDictionary<string, string>> GetAllScriptsRun()
    {
        try
        {

            var sql = $@"
SELECT script_name, text_hash
FROM {ScriptsRunTable} sr
WHERE id = (SELECT MAX(id) FROM {ScriptsRunTable} sr2 WHERE sr2.script_name = sr.script_name)
";
            var results = await ActiveConnection.QueryAsync<ScriptsRunCacheItem>(sql);
            return results.ToDictionary(item => item.script_name, item => item.text_hash);

        }
        catch (Exception ex) when (DryRunOrBootstrap())
        {
            Logger.LogDebug(ex, "Ignoring error getting ScriptsRun when in --dryrun, probably missing table");
            return new Dictionary<string, string>(); // return empty set if nothing has ever been run
        }
    }


    private async Task<IDictionary<string, string>> GetScriptsRunCache() => _scriptsRunCache ??= await GetAllScriptsRun();

    protected virtual string Parameterize(string sql) => sql;

    public async Task<string?> GetCurrentHash(string scriptName)
    {
        var cache = await GetScriptsRunCache();
        if (cache.TryGetValue(scriptName, out var value))
        {
            return value;
        }

        var hashSql = Parameterize($@"
SELECT text_hash FROM  {ScriptsRunTable}
WHERE script_name = @scriptName");

        var hash = await ExecuteScalarAsync<string?>(ActiveConnection, hashSql, new { scriptName });
        return hash;
    }

    public async Task<bool> HasRun(string scriptName, TransactionHandling transactionHandling)
    {
        var cache = await GetScriptsRunCache();
        if (cache.ContainsKey(scriptName))
        {
            return true;
        }

        try
        {
            var hasRunSql = Parameterize(HasRunSql);
            var run = await ExecuteScalarAsync<bool?>(ActiveConnection, hasRunSql, new { scriptName });
            return run ?? false;
        }
        catch (Exception ex) when (DryRunOrBootstrap())
        {
            Logger.LogDebug(ex, "Ignoring exception in dryrun, missing table?");
            return false;
        }
    }

    protected virtual string HasRunSql =>
        $@"
SELECT 1 FROM  {ScriptsRunTable}
WHERE script_name = @scriptName";

    protected virtual object Bool(bool source) => source;

    public async Task InsertScriptRun(string scriptName, string? sql, string hash, bool runOnce, long versionId,
        TransactionHandling transactionHandling)
    {
        var cache = await GetScriptsRunCache();
        cache.Remove(scriptName);

        var insertSql = Parameterize($@"
INSERT INTO {ScriptsRunTable}
(version_id, script_name, text_of_script, text_hash, one_time_script, entry_date, modified_date, entered_by)
VALUES (@versionId, @scriptName, @sql, @hash, @runOnce, @now, @now, @usr)");

        var scriptRun = new DynamicParameters();
        scriptRun.Add(nameof(versionId), versionId);
        scriptRun.Add(nameof(scriptName), scriptName);
        scriptRun.Add(nameof(sql), sql, DbType.String);
        scriptRun.Add(nameof(hash), hash);
        scriptRun.Add(nameof(runOnce), Bool(runOnce));
        scriptRun.Add(Now, DateTime.UtcNow);
        scriptRun.Add(User, GetUserName());

        if (Config!.DeferWritingToRunTables)
        {
            _deferredWrites.Add(conn => ExecuteAsync(conn, insertSql, scriptRun));
        }
        else
        {
            await ExecuteAsync(ActiveConnection, insertSql, scriptRun);
        }
    }

    public async Task InsertScriptRunError(string scriptName, string? sql, string errorSql, string errorMessage, long versionId)
    {
        var insertSql = Parameterize($@"
INSERT INTO {ScriptsRunErrorsTable}
(repository_path, version, script_name, text_of_script, erroneous_part_of_script, error_message, entry_date, modified_date, entered_by)
VALUES (@repositoryPath, @version, @scriptName, @sql, @errorSql, @errorMessage, @now, @now, @usr)");

        var versionSql = Parameterize($"SELECT version FROM {VersionTable} WHERE id = @versionId");

        var version = await ExecuteScalarAsync<string>(ActiveConnection, versionSql, new { versionId });
        var repositoryPath = Config?.RepositoryPath;

        var scriptRunErrors = new DynamicParameters();
        scriptRunErrors.Add(nameof(repositoryPath), repositoryPath);
        scriptRunErrors.Add(nameof(version), version);
        scriptRunErrors.Add(nameof(scriptName), scriptName);
        scriptRunErrors.Add(nameof(sql), sql, DbType.String);
        scriptRunErrors.Add(nameof(errorSql), errorSql, DbType.String);
        scriptRunErrors.Add(nameof(errorMessage), errorMessage, DbType.String);
        scriptRunErrors.Add(Now, DateTime.UtcNow);
        scriptRunErrors.Add(User, GetUserName());
        
        if (Config!.DeferWritingToRunTables)
        {
            _deferredWrites.Add(conn => ExecuteAsync(conn, insertSql, scriptRunErrors));
        }
        else
        {
            await ExecuteAsync(ActiveConnection, insertSql, scriptRunErrors);
        }
    }

    private static async Task Close(DbConnection? conn)
    {
        const int maxNumberOfAttempts = 3;
        var attempts = 0;
        
        // try to close the connection a few times, in case it is in a transient state (e.g. connecting),
        // which will make the close operation fail for some databases.
        do 
        {
            try
            {
                if (conn?.State is ConnectionState.Open or ConnectionState.Connecting)
                {
                    await conn.CloseAsync();
                }
                return;
            }
            catch (Exception) when (attempts++ < maxNumberOfAttempts)
            {
                await Task.Delay(100);
            }
        } while (attempts < maxNumberOfAttempts);
    }

    protected virtual async Task Open(DbConnection? conn)
    {
        if (conn is not null && conn is not { State: ConnectionState.Open or ConnectionState.Connecting })
        {
            await conn.OpenAsync();
            await conn.QueryAsync<string>(_syntax.CurrentDatabase);
        }
    }

    protected async Task<T?> ExecuteScalarAsync<T>(DbConnection conn, string sql, object? parameters = null)
    {
        Logger.LogTrace("SQL: {Sql}", sql);
        Logger.LogTrace("Parameters: {@Parameters}", parameters);

        return await conn.ExecuteScalarAsync<T?>(sql, parameters);
    }

    protected async Task<int> ExecuteAsync(IDbConnection conn, string sql, object? parameters = null)
    {
        Logger.LogTrace("SQL: {Sql}", sql);
        Logger.LogTrace("Parameters: {@Parameters}", parameters);

        return await conn.ExecuteAsync(sql, parameters);
    }

    // in order to prevent fat PR, I will create another PR to use IDbConnection and Dapper.
    protected async Task ExecuteNonQuery(DbConnection conn, string sql, int? timeout)
    {
        Logger.LogTrace("SQL: {Sql}", sql);

        await using var cmd = conn.CreateCommand();
        cmd.CommandText = sql;
        cmd.CommandType = CommandType.Text;

        if (timeout.HasValue)
        {
            cmd.CommandTimeout = timeout.Value;
        }

        await cmd.ExecuteNonQueryAsync();
    }
    
    
    private bool DryRunOrBootstrap()
    {
        return (Config?.DryRun ?? throw new InvalidOperationException("No configuration available.")) 
               || Config.Environment == GrateEnvironment.InternalBootstrap;
    }
    

    public async ValueTask DisposeAsync()
    {
        if (_deferredWrites.Any())
        {
            await OpenActiveConnection();
            foreach (var deferredWrite in _deferredWrites.ToArray())
            {
                await deferredWrite(ActiveConnection);
            }
            _deferredWrites.Clear();
        }
        await CloseConnection();
        await CloseAdminConnection();
        await Close(ActiveConnection);
        
        GC.SuppressFinalize(this);
    }

    public abstract Task RestoreDatabase(string backupPath);
    
    object ICloneable.Clone() => this with { };
}
