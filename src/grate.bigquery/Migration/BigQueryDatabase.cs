using System.Data.Common;
using System.Diagnostics;
using System.Globalization;
using System.Net;
using System.Security.Claims;
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
    /// How many times grate sends a request, or reads a job, while its failure is one that passes: the request failed
    /// on its way, or BigQuery refused it for now (<c>rateLimitExceeded</c>, <c>backendError</c>).
    /// </summary>
    private const int MaxAttempts = 5;

    // how long BigQuery holds a jobs.query request for the query to finish - Google's own default
    private static readonly TimeSpan QueryRequestWait = TimeSpan.FromSeconds(10);

    // how long one wait for a job lasts when the command timeout is 0 - grate then waits again, without limit
    private static readonly TimeSpan WaitWithoutLimit = TimeSpan.FromMinutes(5);

    // the client needs a limit for a read, and a read of grate's tables never takes a day
    private static readonly TimeSpan ReadWithoutLimit = TimeSpan.FromDays(1);

    private ILogger _logger = logger;
    private SharedClient? _client;
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

        // a clone shares its original's client while both reach the same project, location and endpoint - grate
        // clones the database for each of its internal migrations, and a library can configure a clone for another
        if (_client is not null && !_client.Serves(_settings))
        {
            _client.Release();
            _client = null;
        }

        _client ??= new SharedClient(await BigQueryClientFactory.CreateAsync(_settings), _settings);
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
        if (await IsInitialBootstrap())
        {
            // the bootstrap scripts create grate's tables, so the first bootstrap versions itself before its version
            // table exists - its deferred history belongs to the version the next internal migration inserts
            _logger.LogDebug("No version table in {DatabaseName} yet - using version id 1", DatabaseName);
            return 1;
        }

        // the next id is one above the highest - only one migration runs against a database at a time
        var rows = await QueryAsync($"SELECT COALESCE(MAX(id), 0) + 1 AS id FROM {VersionTable}");
        var versionId = (long)rows.Single()["id"];

        await ExecuteAsync(
            $"""
            INSERT INTO {VersionTable} (id, repository_path, version, entry_date, modified_date, entered_by, status)
            VALUES (@id, CAST(@repository_path AS STRING), @version, CURRENT_TIMESTAMP(), CURRENT_TIMESTAMP(), @entered_by, @status)
            """,
            new BigQueryParameter("id", BigQueryDbType.Int64, versionId),
            new BigQueryParameter("repository_path", BigQueryDbType.String, _config?.RepositoryPath),
            new BigQueryParameter("version", BigQueryDbType.String, newVersion),
            new BigQueryParameter("entered_by", BigQueryDbType.String, UserName),
            new BigQueryParameter("status", BigQueryDbType.String, MigrationStatus.InProgress));

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
        await ExecuteAsync(sql, connectionType == ConnectionType.Admin);
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
                CAST(@text_of_script AS STRING),
                @text_hash,
                @one_time_script,
                CURRENT_TIMESTAMP(),
                CURRENT_TIMESTAMP(),
                @entered_by
            FROM {ScriptsRunTable}
            """,
            new BigQueryParameter("version_id", BigQueryDbType.Int64, versionId),
            new BigQueryParameter("script_name", BigQueryDbType.String, scriptName),
            new BigQueryParameter("text_of_script", BigQueryDbType.String, sql),
            new BigQueryParameter("text_hash", BigQueryDbType.String, hash),
            new BigQueryParameter("one_time_script", BigQueryDbType.Bool, runOnce),
            new BigQueryParameter("entered_by", BigQueryDbType.String, UserName));
    }

    public async Task InsertScriptRunError(string scriptName, string? sql, string errorSql, string errorMessage, long versionId)
    {
        await WriteAsync(
            $"""
            INSERT INTO {ScriptsRunErrorsTable} (id, repository_path, version, script_name, text_of_script, erroneous_part_of_script, error_message, entry_date, modified_date, entered_by)
            SELECT
                next.id,
                CAST(@repository_path AS STRING),
                v.version,
                @script_name,
                CAST(@text_of_script AS STRING),
                @erroneous_part_of_script,
                @error_message,
                CURRENT_TIMESTAMP(),
                CURRENT_TIMESTAMP(),
                @entered_by
            FROM (SELECT COALESCE(MAX(id), 0) + 1 AS id FROM {ScriptsRunErrorsTable}) AS next
            LEFT JOIN (SELECT version FROM {VersionTable} WHERE id = @version_id) AS v ON TRUE
            """,
            new BigQueryParameter("version_id", BigQueryDbType.Int64, versionId),
            new BigQueryParameter("repository_path", BigQueryDbType.String, _config?.RepositoryPath),
            new BigQueryParameter("script_name", BigQueryDbType.String, scriptName),
            new BigQueryParameter("text_of_script", BigQueryDbType.String, sql),
            new BigQueryParameter("erroneous_part_of_script", BigQueryDbType.String, errorSql),
            new BigQueryParameter("error_message", BigQueryDbType.String, errorMessage),
            new BigQueryParameter("entered_by", BigQueryDbType.String, UserName));
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
        await ExecuteAsync(
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
        await ExecuteAsync(
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

        // the last of a database and its clones to be disposed disposes the client
        _client?.Release();
        _client = null;

        GC.SuppressFinalize(this);
    }

    public object Clone()
    {
        // a clone shares the client, but nothing one migration has read or still has to write
        var clone = (BigQueryDatabase)MemberwiseClone();
        clone._client = _client?.Share();
        clone._scriptsRun = null;
        clone._deferredWrites = [];
        return clone;
    }

    private BigQueryClient Client =>
        _client?.Client ?? throw new InvalidOperationException($"{nameof(InitializeConnections)} has not run");

    private BigQueryConnectionSettings Settings =>
        _settings ?? throw new InvalidOperationException($"{nameof(InitializeConnections)} has not run");

    private string DatasetId => Settings.Dataset!;

    /// <summary>
    /// While grate bootstraps its own tables it runs under this environment, and its writes to them must wait until
    /// they exist.
    /// </summary>
    private bool Bootstrapping => _config?.Environment == GrateEnvironment.InternalBootstrap;

    // as AnsiSqlDatabase.IsInitialBootstrap - grate's first bootstrap runs before its version table exists
    private async Task<bool> IsInitialBootstrap() => Bootstrapping && !await VersionTableExists();

    // as grate's other providers record who ran a migration
    private static string UserName => ClaimsPrincipal.Current?.Identity?.Name ?? Environment.UserName;

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
            _deferredWrites.Add(async () => await ExecuteAsync(sql, parameters));
            return;
        }

        await ExecuteAsync(sql, parameters);
    }

    /// <summary>
    /// Reads grate's own tables. A read changes nothing, so a read that fails on its way is simply run again.
    /// </summary>
    private async Task<BigQueryResults> QueryAsync(string sql, params BigQueryParameter[] parameters)
    {
        var options = new QueryOptions
        {
            DefaultDataset = Client.GetDatasetReference(DatasetId),
            UseQueryCache = false,
        };
        var resultsOptions = new GetQueryResultsOptions { Timeout = Limit(admin: false) ?? ReadWithoutLimit };

        try
        {
            return await ReadAsync(() => Client.ExecuteQueryAsync(sql, parameters, options, resultsOptions));
        }
        catch (GoogleApiException ex)
        {
            throw new BigQueryDbException(ex);
        }
    }

    private Task ExecuteAsync(string sql, params BigQueryParameter[] parameters) =>
        ExecuteAsync(sql, false, parameters);

    /// <summary>
    /// Runs a script, or a statement whose rows grate does not read - so a query that has finished when BigQuery
    /// answers needs no more requests.
    /// </summary>
    private async Task ExecuteAsync(string sql, bool admin, params BigQueryParameter[] parameters)
    {
        var limit = Limit(admin);
        var waited = Stopwatch.StartNew();

        var (job, finished) = await SubmitAsync(sql, admin, parameters, limit);
        if (!finished)
        {
            await WaitAsync(job, limit, waited);
        }
    }

    // 0 is no limit, as with grate's other providers
    private TimeSpan? Limit(bool admin)
    {
        var timeout = admin ? _config?.AdminCommandTimeout : _config?.CommandTimeout;
        return timeout > 0 ? TimeSpan.FromSeconds(timeout.Value) : null;
    }

    /// <summary>
    /// Starts the query with <c>jobs.query</c>, under a request id of grate's own. A request that fails on its way, or
    /// that BigQuery refuses for now, is sent again with the same id: BigQuery runs a request id once, so the query
    /// never runs twice. A query BigQuery ran and that failed is not run again - a script's statements before the
    /// failure have run.
    /// </summary>
    private async Task<(JobReference Job, bool Finished)> SubmitAsync(
        string sql, bool admin, BigQueryParameter[] parameters, TimeSpan? limit)
    {
        var request = new QueryRequest
        {
            Query = sql,
            UseLegacySql = false,
            UseQueryCache = false,
            DefaultDataset = admin ? null : Client.GetDatasetReference(DatasetId),
            Location = Settings.Location,
            ParameterMode = parameters.Length == 0 ? null : "named",
            QueryParameters = parameters.Length == 0 ? null : parameters.Select(ToQueryParameter).ToList(),
            RequestId = Guid.NewGuid().ToString(),

            // a job, so that grate can wait for it, cancel it and name it
            JobCreationMode = "JOB_CREATION_REQUIRED",

            // how long BigQuery holds the request for the query to finish - grate then waits on the job
            TimeoutMs = (long)(limit < QueryRequestWait ? limit.Value : QueryRequestWait).TotalMilliseconds,
        };

        for (var attempt = 1; ; attempt++)
        {
            try
            {
                var response = await Client.Service.Jobs.Query(request, Settings.ProjectId).ExecuteAsync();

                // errors in a finished answer are read from the job, as when it had not finished
                return (response.JobReference, response.JobComplete == true && !(response.Errors?.Count > 0));
            }
            catch (Exception ex) when (attempt < MaxAttempts && IsRetriable(ex))
            {
                var delay = Backoff(attempt);
                _logger.LogWarning("BigQuery request {RequestId} failed, and will be sent again: attempt {Attempt}, in {Delay}: {Error}",
                    request.RequestId, attempt, delay, ex.Message);
                await Task.Delay(delay);
            }
            catch (GoogleApiException ex)
            {
                throw new BigQueryDbException(ex);
            }
        }
    }

    /// <summary>
    /// Waits for the job to finish, up to the command timeout. A failure to read the job is not taken as the job's
    /// failure - BigQuery's record of the job says which it was.
    /// </summary>
    private async Task WaitAsync(JobReference job, TimeSpan? limit, Stopwatch waited)
    {
        for (var attempt = 1; ; attempt++)
        {
            var remaining = limit - waited.Elapsed;
            if (remaining <= TimeSpan.Zero)
            {
                throw await OutcomeUnknownAsync(job, $"did not finish within {limit!.Value.TotalSeconds} seconds", null);
            }

            try
            {
                await Client.GetQueryResultsAsync(job, new GetQueryResultsOptions { Timeout = remaining ?? WaitWithoutLimit });
                return;
            }
            catch (TimeoutException ex)
            {
                if (limit is not null)
                {
                    throw await OutcomeUnknownAsync(job, $"did not finish within {limit.Value.TotalSeconds} seconds", ex);
                }

                // no limit - wait again
            }
            catch (Exception ex) when (ex is GoogleApiException or HttpRequestException)
            {
                BigQueryJob current;
                try
                {
                    current = await ReadAsync(() => Client.GetJobAsync(job));
                }
                catch (Exception readFailure) when (readFailure is GoogleApiException or HttpRequestException)
                {
                    throw await OutcomeUnknownAsync(job, "could not be read", readFailure);
                }

                if (current.State == JobState.Done && current.Status.ErrorResult is not null)
                {
                    throw Failure(current);
                }

                if (attempt >= MaxAttempts)
                {
                    throw await OutcomeUnknownAsync(job, "could not be read", ex);
                }

                await Task.Delay(Backoff(attempt));
            }
        }
    }

    /// <summary>
    /// Asks BigQuery to cancel a job grate stops waiting for, and describes it. Cancelling is best effort: the job can
    /// still finish, so its outcome is unknown.
    /// </summary>
    private async Task<BigQueryDbException> OutcomeUnknownAsync(JobReference job, string what, Exception? cause)
    {
        try
        {
            await Client.CancelJobAsync(job);
        }
        catch (Exception ex) when (ex is GoogleApiException or HttpRequestException)
        {
            _logger.LogWarning("Could not cancel BigQuery job {JobId}: {Error}", job.JobId, ex.Message);
        }

        return new BigQueryDbException(
            $"BigQuery job {job.JobId} {what}. grate asked BigQuery to cancel it, but the job may still finish: check job " +
            $"{job.JobId} in BigQuery before you run grate again.",
            job.JobId,
            cause);
    }

    // reading changes nothing, so a read that fails on its way is safe to try again
    private static async Task<T> ReadAsync<T>(Func<Task<T>> read)
    {
        for (var attempt = 1; ; attempt++)
        {
            try
            {
                return await read();
            }
            catch (Exception ex) when (attempt < MaxAttempts && IsRetriable(ex))
            {
                await Task.Delay(Backoff(attempt));
            }
        }
    }

    private static BigQueryDbException Failure(BigQueryJob job)
    {
        try
        {
            job.ThrowOnAnyError();
        }
        catch (GoogleApiException ex)
        {
            return new BigQueryDbException(ex, job.Reference.JobId);
        }

        throw new InvalidOperationException($"BigQuery job {job.Reference.JobId} failed, but reports no errors");
    }

    // a request that failed on its way, or that BigQuery refused for now
    private static bool IsRetriable(Exception exception) => exception switch
    {
        HttpRequestException => true,
        GoogleApiException ex => (int)ex.HttpStatusCode >= 500
            || ex.HttpStatusCode == HttpStatusCode.TooManyRequests
            || new BigQueryDbException(ex).IsTransient,
        _ => false,
    };

    private static TimeSpan Backoff(int attempt) => TimeSpan.FromSeconds(Math.Pow(2, attempt));

    // the client turns its own parameters into the REST API's internally, and grate uses only these three types
    private static QueryParameter ToQueryParameter(BigQueryParameter parameter) => new()
    {
        Name = parameter.Name,
        ParameterType = new QueryParameterType
        {
            Type = parameter.Type switch
            {
                BigQueryDbType.Int64 => "INT64",
                BigQueryDbType.String => "STRING",
                BigQueryDbType.Bool => "BOOL",
                _ => throw new NotSupportedException($"grate passes no {parameter.Type} parameters to BigQuery"),
            },
        },
        ParameterValue = new QueryParameterValue
        {
            Value = parameter.Value switch
            {
                null => null,
                bool value => value ? "true" : "false",
                IFormattable value => value.ToString(null, CultureInfo.InvariantCulture),
                var value => value.ToString(),
            },
        },
    };

    private sealed class NoConnection : IDisposable
    {
        public void Dispose()
        {
            // nothing to close
        }
    }

    /// <summary>
    /// A <see cref="BigQueryClient"/> that a database shares with its clones. The client is bound to a project, a
    /// default location and an endpoint (the dataset is named on each call), and the last database to let it go
    /// disposes it.
    /// </summary>
    private sealed class SharedClient(BigQueryClient client, BigQueryConnectionSettings settings)
    {
        private int _users = 1;

        public BigQueryClient Client { get; } = client;

        public bool Serves(BigQueryConnectionSettings other) =>
            other.ProjectId == settings.ProjectId
            && other.Location == settings.Location
            && other.Endpoint == settings.Endpoint;

        public SharedClient Share()
        {
            Interlocked.Increment(ref _users);
            return this;
        }

        public void Release()
        {
            if (Interlocked.Decrement(ref _users) == 0)
            {
                Client.Dispose();
            }
        }
    }
}
