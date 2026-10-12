using System.Data.Common;
using System.Net;
using Google;
using Google.Apis.Bigquery.v2.Data;
using Google.Cloud.BigQuery.V2;
using grate.BigQuery.Infrastructure;
using grate.Configuration;
using grate.Infrastructure;
using grate.Migration;
using Microsoft.Extensions.Logging;

namespace grate.BigQuery.Migration;

/// <summary>
/// grate's provider for Google BigQuery. A dataset is the database: the migrations' objects and grate's own tables all
/// live in it, grate's as <c>{schema}_{table}</c>, as a dataset holds no schemas. Every call is a BigQuery job through
/// <see cref="BigQueryClient"/>, so there are no connections, and no transactions - BigQuery runs no DDL in one. A
/// script runs whole, as one multi-statement job, so a failed script leaves the statements before the failure done:
/// write scripts that are safe to run again.
/// </summary>
public class BigQueryDatabase(ILogger<BigQueryDatabase> logger) : IDatabase
{
    public static string Type => "bigquery";
    public static ISyntax Syntax { get; } = new BigQuerySyntax();

    private const string NotVersioning = "0.0.0.0";

    /// <summary>
    /// How many times a job is tried while BigQuery says its failure will pass - a table takes 5 metadata changes per
    /// 10 seconds, and DML on grate's tables counts.
    /// </summary>
    private const int MaxAttempts = 5;

    private static readonly string[] RetryableReasons = ["rateLimitExceeded", "backendError"];

    private ILogger _logger = logger;
    private BigQueryClient? _client;
    private GrateConfiguration? _config;
    private BigQueryConnectionSettings? _settings;
    private string _schemaName = "";
    private string _scriptsRunTableName = "";
    private string _scriptsRunErrorsTableName = "";
    private string _versionTableName = "";

    // the latest hash of every script run, read once per migration - grate asks script by script
    private Dictionary<string, string>? _scriptsRun;

    // grate records its own bootstrap scripts while they are still creating its tables - written once they exist
    private List<Func<Task>> _deferredWrites = [];

    public string? ServerName => _settings?.ProjectId;
    public string? DatabaseName => _settings?.Dataset;
    public string DatabaseType => Type;
    public string MasterDatabaseName => string.Empty; // a project has no database to administer the others from
    public bool SupportsDdlTransactions => false;
    public bool SplitBatchStatements => false;
    public bool SupportsSchemas => false;

    public string ScriptsRunTable => Table(_scriptsRunTableName);
    public string ScriptsRunErrorsTable => Table(_scriptsRunErrorsTableName);
    public string VersionTable => Table(_versionTableName);

    public DbConnection ActiveConnection
    {
        set
        {
            // no connections - every call is a job
        }
    }

    public async Task InitializeConnections(GrateConfiguration configuration)
    {
        ArgumentNullException.ThrowIfNull(configuration);

        _logger.LogInformation("Initializing connections.");

        _settings = BigQueryConnectionSettings.Parse(configuration.ConnectionString);
        if (_settings.Dataset is null)
        {
            throw new ArgumentException(
                $"The BigQuery connection string has no {BigQueryConnectionSettings.DatasetKey} - the dataset is the database grate migrates",
                nameof(configuration));
        }

        _schemaName = configuration.SchemaName;
        _scriptsRunTableName = configuration.ScriptsRunTableName;
        _scriptsRunErrorsTableName = configuration.ScriptsRunErrorsTableName;
        _versionTableName = configuration.VersionTableName;
        _config = configuration;

        // a clone keeps its original's client - grate clones the database for each of its internal migrations
        _client ??= await BigQueryClientFactory.CreateAsync(_settings);
    }

    public Task OpenConnection() => Task.CompletedTask;
    public Task CloseConnection() => Task.CompletedTask;
    public Task OpenAdminConnection() => Task.CompletedTask;
    public Task CloseAdminConnection() => Task.CompletedTask;
    public Task OpenActiveConnection() => Task.CompletedTask;
    public Task<IDisposable> OpenNewActiveConnection() => Task.FromResult<IDisposable>(new NoConnection());

    public void SetDefaultConnectionActive()
    {
        // no connections - every call is a job
    }

    public void SetLogger(ILogger logger) => _logger = logger;

    public async Task CreateDatabase()
    {
        // the dataset's location comes from the connection string, or is BigQuery's default
        await Client.GetOrCreateDatasetAsync(DatasetId, new Dataset { Location = Settings.Location });
    }

    public async Task DropDatabase()
    {
        try
        {
            await Client.DeleteDatasetAsync(DatasetId, new DeleteDatasetOptions { DeleteContents = true });
        }
        catch (GoogleApiException ex) when (ex.HttpStatusCode == HttpStatusCode.NotFound)
        {
            // nothing to drop
        }
    }

    public Task RestoreDatabase(string backupPath) =>
        throw new NotSupportedException("Restoring a database from a backup is not supported for BigQuery.");

    public async Task<bool> DatabaseExists()
    {
        try
        {
            await Client.GetDatasetAsync(DatasetId);
            return true;
        }
        catch (GoogleApiException ex) when (ex.HttpStatusCode == HttpStatusCode.NotFound)
        {
            return false;
        }
    }

    public async Task<string> GetCurrentVersion()
    {
        try
        {
            var rows = await QueryAsync($"""
                SELECT version
                FROM {VersionTable}
                ORDER BY id DESC
                LIMIT 1
                """);

            return rows.Select(x => (string?)x["version"]).FirstOrDefault() ?? NotVersioning;
        }
        catch (BigQueryDbException ex)
        {
            // a dataset grate has not seen yet has no version table
            _logger.LogDebug(ex, "Could not read the current version of {DatabaseName} - none yet?", DatabaseName);
            return NotVersioning;
        }
    }

    public async Task<long> VersionTheDatabase(string newVersion)
    {
        long versionId;

        try
        {
            // the next id is one above the highest - only one migration runs against a database at a time
            var rows = await QueryAsync(
                $"""
                DECLARE new_id INT64 DEFAULT (SELECT COALESCE(MAX(id), 0) + 1 FROM {VersionTable});

                INSERT INTO {VersionTable} (id, repository_path, version, entry_date, modified_date, entered_by, status)
                VALUES (new_id, @repository_path, @version, @now, @now, @entered_by, @status);

                SELECT new_id AS id;
                """,
                new BigQueryParameter("repository_path", BigQueryDbType.String, _config?.RepositoryPath),
                new BigQueryParameter("version", BigQueryDbType.String, newVersion),
                new BigQueryParameter("now", BigQueryDbType.Timestamp, DateTime.UtcNow),
                new BigQueryParameter("entered_by", BigQueryDbType.String, Environment.UserName),
                new BigQueryParameter("status", BigQueryDbType.String, MigrationStatus.InProgress));

            versionId = (long)rows.Single()["id"];
        }
        catch (BigQueryDbException ex)
        {
            // the bootstrap versions itself before its version table exists, as with grate's other providers
            _logger.LogDebug(ex, "Could not find the version table in {DatabaseName} - using version id 1", DatabaseName);
            versionId = 1;
        }

        _logger.LogInformation(" Versioning {DbName} database with version {Version}.", DatabaseName, newVersion);

        return versionId;
    }

    public void Rollback()
    {
        // nothing to roll back - no migration runs in a transaction
    }

    public async Task RunSql(string sql, ConnectionType connectionType, TransactionHandling transactionHandling)
    {
        _logger.LogTrace("[SQL] Running (on connection '{ConnType}', transaction handling '{TransactionHandling}'): \n{Sql}",
            connectionType.ToString(), transactionHandling, sql);

        // admin scripts may run before the dataset exists, so they get no default dataset
        await QueryAsync(sql, connectionType == ConnectionType.Admin);
    }

    public async Task<string?> GetCurrentHash(string scriptName)
    {
        var scriptsRun = await ScriptsRunAsync();
        return scriptsRun.GetValueOrDefault(scriptName);
    }

    public async Task<bool> HasRun(string scriptName, TransactionHandling transactionHandling)
    {
        var scriptsRun = await ScriptsRunAsync();
        return scriptsRun.ContainsKey(scriptName);
    }

    public async Task InsertScriptRun(string scriptName, string? sql, string hash, bool runOnce, long versionId,
        TransactionHandling transactionHandling)
    {
        var scriptsRun = await ScriptsRunAsync();
        scriptsRun[scriptName] = hash;

        await WriteAsync(
            $"""
            INSERT INTO {ScriptsRunTable} (id, version_id, script_name, text_of_script, text_hash, one_time_script, entry_date, modified_date, entered_by)
            SELECT
                COALESCE(MAX(id), 0) + 1,
                @version_id,
                @script_name,
                @text_of_script,
                @text_hash,
                @one_time_script,
                @now,
                @now,
                @entered_by
            FROM {ScriptsRunTable}
            """,
            new BigQueryParameter("version_id", BigQueryDbType.Int64, versionId),
            new BigQueryParameter("script_name", BigQueryDbType.String, scriptName),
            new BigQueryParameter("text_of_script", BigQueryDbType.String, sql),
            new BigQueryParameter("text_hash", BigQueryDbType.String, hash),
            new BigQueryParameter("one_time_script", BigQueryDbType.Bool, runOnce),
            new BigQueryParameter("now", BigQueryDbType.Timestamp, DateTime.UtcNow),
            new BigQueryParameter("entered_by", BigQueryDbType.String, Environment.UserName));
    }

    public async Task InsertScriptRunError(string scriptName, string? sql, string errorSql, string errorMessage, long versionId)
    {
        await WriteAsync(
            $"""
            DECLARE script_version STRING DEFAULT (SELECT version FROM {VersionTable} WHERE id = @version_id);

            INSERT INTO {ScriptsRunErrorsTable} (id, repository_path, version, script_name, text_of_script, erroneous_part_of_script, error_message, entry_date, modified_date, entered_by)
            SELECT
                COALESCE(MAX(id), 0) + 1,
                @repository_path,
                script_version,
                @script_name,
                @text_of_script,
                @erroneous_part_of_script,
                @error_message,
                @now,
                @now,
                @entered_by
            FROM {ScriptsRunErrorsTable};
            """,
            new BigQueryParameter("version_id", BigQueryDbType.Int64, versionId),
            new BigQueryParameter("repository_path", BigQueryDbType.String, _config?.RepositoryPath),
            new BigQueryParameter("script_name", BigQueryDbType.String, scriptName),
            new BigQueryParameter("text_of_script", BigQueryDbType.String, sql),
            new BigQueryParameter("erroneous_part_of_script", BigQueryDbType.String, errorSql),
            new BigQueryParameter("error_message", BigQueryDbType.String, errorMessage),
            new BigQueryParameter("now", BigQueryDbType.Timestamp, DateTime.UtcNow),
            new BigQueryParameter("entered_by", BigQueryDbType.String, Environment.UserName));
    }

    public async Task<bool> VersionTableExists() => await ExistingTable(_schemaName, _versionTableName) is not null;

    public async Task<bool> GrateInternalTablesAreProperlyLogged()
    {
        const string tableName = "GrateScriptsRun";

        if (await ExistingTable(_schemaName, tableName) is null)
        {
            return false;
        }

        var rows = await QueryAsync($"""
            SELECT 1 AS logged
            FROM {Table(tableName)}
            WHERE script_name = '02_create_scripts_run_table.sql'
            LIMIT 1
            """);

        return rows.Any();
    }

    public async Task ChangeVersionStatus(string status, long versionId)
    {
        await QueryAsync(
            $"""
            UPDATE {VersionTable}
            SET status = @status
            WHERE id = @version_id
            """,
            new BigQueryParameter("status", BigQueryDbType.String, status),
            new BigQueryParameter("version_id", BigQueryDbType.Int64, versionId));
    }

    public async Task DeleteVersionRecord(long versionId)
    {
        await QueryAsync(
            $"""
            DELETE FROM {VersionTable}
            WHERE id = @version_id
            """,
            new BigQueryParameter("version_id", BigQueryDbType.Int64, versionId));
    }

    public async Task<string?> ExistingTable(string schemaName, string tableName)
    {
        try
        {
            await Client.GetTableAsync(DatasetId, Syntax.TableWithSchema(schemaName, tableName));
            return tableName;
        }
        catch (GoogleApiException ex) when (ex.HttpStatusCode == HttpStatusCode.NotFound)
        {
            return null;
        }
    }

    public IEnumerable<string> GetStatements(string sql) => Syntax.StatementSplitter.Split(sql);

    public void ThrowScriptFailed(MigrationsFolder folder, string file, string? scriptText, Exception exception) =>
        throw new BigQueryScriptFailed(folder, file, scriptText, exception);

    public async ValueTask DisposeAsync()
    {
        // the bootstrap has created grate's tables by now, so its records of itself can be written
        foreach (var write in _deferredWrites)
        {
            await write();
        }

        _deferredWrites.Clear();
        GC.SuppressFinalize(this);
    }

    public object Clone()
    {
        // a clone shares the client, but nothing one migration has read or still has to write
        var clone = (BigQueryDatabase)MemberwiseClone();
        clone._scriptsRun = null;
        clone._deferredWrites = [];
        return clone;
    }

    private BigQueryClient Client =>
        _client ?? throw new InvalidOperationException($"{nameof(InitializeConnections)} has not run");

    private BigQueryConnectionSettings Settings =>
        _settings ?? throw new InvalidOperationException($"{nameof(InitializeConnections)} has not run");

    private string DatasetId => Settings.Dataset!;

    /// <summary>
    /// While grate bootstraps its own tables it runs under this environment, and its writes to them must wait until
    /// they exist.
    /// </summary>
    private bool Bootstrapping => _config?.Environment == GrateEnvironment.InternalBootstrap;

    private string Table(string tableName) =>
        $"`{Settings.ProjectId}.{DatasetId}.{Syntax.TableWithSchema(_schemaName, tableName)}`";

    private async Task<Dictionary<string, string>> ScriptsRunAsync()
    {
        if (_scriptsRun is not null)
        {
            return _scriptsRun;
        }

        try
        {
            var rows = await QueryAsync($"""
                SELECT
                    script_name,
                    text_hash
                FROM (
                    SELECT
                        script_name,
                        text_hash,
                        ROW_NUMBER() OVER (PARTITION BY script_name ORDER BY id DESC) AS latest
                    FROM {ScriptsRunTable}
                )
                WHERE latest = 1
                """);

            _scriptsRun = rows.ToDictionary(x => (string)x["script_name"], x => (string)x["text_hash"]);
        }
        catch (BigQueryDbException ex) when (Bootstrapping || _config?.DryRun == true)
        {
            // nothing has run yet - the bootstrap is creating the table this reads
            _logger.LogDebug(ex, "Could not read the scripts run in {DatabaseName} - none yet", DatabaseName);
            _scriptsRun = [];
        }

        return _scriptsRun;
    }

    private async Task WriteAsync(string sql, params BigQueryParameter[] parameters)
    {
        if (Bootstrapping)
        {
            _deferredWrites.Add(async () => await QueryAsync(sql, parameters));
            return;
        }

        await QueryAsync(sql, parameters);
    }

    private Task<BigQueryResults> QueryAsync(string sql, params BigQueryParameter[] parameters) =>
        QueryAsync(sql, false, parameters);

    private async Task<BigQueryResults> QueryAsync(string sql, bool admin, params BigQueryParameter[] parameters)
    {
        var options = new QueryOptions
        {
            DefaultDataset = admin ? null : Client.GetDatasetReference(DatasetId),
            UseQueryCache = false,
        };

        var timeout = admin ? _config?.AdminCommandTimeout : _config?.CommandTimeout;
        var resultsOptions = new GetQueryResultsOptions
        {
            Timeout = timeout > 0 ? TimeSpan.FromSeconds(timeout.Value) : null,
        };

        for (var attempt = 1; ; attempt++)
        {
            try
            {
                return await Client.ExecuteQueryAsync(sql, parameters, options, resultsOptions);
            }
            catch (GoogleApiException ex) when (attempt < MaxAttempts && IsRetryable(ex))
            {
                var delay = TimeSpan.FromSeconds(Math.Pow(2, attempt));
                _logger.LogWarning("BigQuery job failed, and will be tried again: attempt {Attempt}, in {Delay}: {Error}",
                    attempt, delay, ex.Message);
                await Task.Delay(delay);
            }
            catch (GoogleApiException ex)
            {
                throw new BigQueryDbException(ex);
            }
        }
    }

    private static bool IsRetryable(GoogleApiException exception) =>
        exception.Error?.Errors?.Any(x => RetryableReasons.Contains(x.Reason)) ?? false;

    private sealed class NoConnection : IDisposable
    {
        public void Dispose()
        {
            // nothing to close
        }
    }
}
