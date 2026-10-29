using System.Data;
using System.Data.Common;
using System.Security.Claims;
using Dapper;
using grate.Configuration;
using grate.Exceptions;
using grate.Infrastructure;
using grate.Migration;
using grate.oracle.Infrastructure;
using grate.Oracle.Infrastructure;
using Microsoft.Extensions.Logging;
using Oracle.ManagedDataAccess.Client;
using static System.StringSplitOptions;

namespace grate.Oracle.Migration;

public record OracleDatabase : AnsiSqlDatabase
{
    public override string MasterDatabaseName => "oracle";
    public override string DatabaseType => Type;
    public OracleDatabase(ILogger<OracleDatabase> logger)
        : base(logger, Syntax)
    {
    }

    public override bool SupportsDdlTransactions => false;
    public override bool SupportsSchemas => false;
    
    public static string Type => "oracle";
    public static ISyntax Syntax { get; } = new OracleSyntax();

    protected override DbConnection GetSqlConnection(string? connectionString) => new OracleConnection(connectionString);

    protected override string ExistsSql(string tableSchema, string fullTableName) =>
        $@"
SELECT table_name FROM user_tables
WHERE 
lower(table_name) = '{fullTableName.ToLowerInvariant()}'
";

    protected override string ExistsSql(string tableSchema, string fullTableName, string columnName) =>
$@"
SELECT * FROM user_tab_columns
WHERE 
lower(table_name) = '{fullTableName.ToLowerInvariant()}' AND
lower(column_name) = '{columnName.ToLowerInvariant()}'
";

    protected override string CurrentVersionSql => $@"
SELECT version
FROM 
    (SELECT version,
            ROW_NUMBER() OVER (ORDER BY version DESC) AS version_row_number 
    FROM {VersionTable})
WHERE  version_row_number <= 1
";

    // protected override async Task CreateScriptsRunTable()
    // {
    //     if (!await ScriptsRunTableExists())
    //     {
    //         await base.CreateScriptsRunTable();
    //         await CreateIdSequence(ScriptsRunTable);
    //         await CreateIdInsertTrigger(ScriptsRunTable);
    //     }
    // }

    // protected override async Task CreateScriptsRunErrorsTable()
    // {
    //     if (!await ScriptsRunErrorsTableExists())
    //     {
    //         await base.CreateScriptsRunErrorsTable();
    //         await CreateIdSequence(ScriptsRunErrorsTable);
    //         await CreateIdInsertTrigger(ScriptsRunErrorsTable);
    //     }
    // }

    public override Task RestoreDatabase(string backupPath)
    {
        throw new System.NotImplementedException("Restoring a database from file is not currently supported for Oracle.");
    }

    // protected override async Task CreateVersionTable()
    // {
    //     if (!await VersionTableExists())
    //     {
    //         await base.CreateVersionTable();
    //         await CreateIdSequence(VersionTable);
    //         await CreateIdInsertTrigger(VersionTable);
    //     }
    // }

    protected override string Parameterize(string sql) => sql.Replace("@", ":");
    protected override object Bool(bool source) => source ? '1' : '0';

    public override async Task<long> VersionTheDatabase(string newVersion)
    {
        if (await IsInitialBootstrap())
        {
            return 1;
        }

        var (_, versionTable) = await ResolveVersionTable();
        var includeStatus = await VersionTableSupportsStatus(versionTable);
        var sql = (string)$@"
INSERT INTO {versionTable}
(repository_path, version, entry_date, modified_date, entered_by{(includeStatus ? ", status" : "")})
VALUES(:repositoryPath, :newVersion, :entryDate, :modifiedDate, :enteredBy{(includeStatus ? ", :status" : "")})
RETURNING id into :id
";
        var repositoryPath = Config?.RepositoryPath;
        
        var parameters = new
        {
            repositoryPath,
            newVersion,
            entryDate = DateTime.UtcNow,
            modifiedDate = DateTime.UtcNow,
            enteredBy = GetUserName()
        };
        var dynParams = new DynamicParameters(parameters);
        if (includeStatus)
        {
            dynParams.Add("status", MigrationStatus.InProgress);
        }
        dynParams.Add(":id", dbType: DbType.Int64, direction: ParameterDirection.Output);

        await ActiveConnection.ExecuteAsync(sql, dynParams);
        var versionId = dynParams.Get<long>(":id");

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

    public override string DatabaseName
    {
        get
        {
            var tokens = Tokenize(Connection.ConnectionString);
            return GetValue(tokens, "Proxy User Id") ?? GetValue(tokens, "User ID") ?? base.DatabaseName;
        }
    }

    // since the sql is parameterized, we no longer need to override this method anymore.
    // public override async Task ChangeVersionStatus(string status, long versionId)
    // {
    //     var sql = (string)$@"
    //         UPDATE {VersionTable}
    //         SET status = :status
    //         WHERE id = :versionId";

    //     var parameters = new
    //     {
    //         status,
    //         versionId,
    //     };

    //     await Connection.ExecuteAsync(
    //         sql,
    //         parameters);
    // }

    private static IDictionary<string, string?> Tokenize(string? connectionString)
    {
        var tokens = connectionString?.Split(";", RemoveEmptyEntries | TrimEntries) ?? Enumerable.Empty<string>();
        var keyPairs = tokens.Select(t => t.Split("=", TrimEntries));
        return keyPairs.ToDictionary(pair => pair[0], pair => (string?)pair[1]);
    }

    private static string? GetValue(IDictionary<string, string?> dictionary, string key) =>
        dictionary.TryGetValue(key, out string? value) ? value : null ??
        (dictionary.TryGetValue(key.ToUpperInvariant(), out string? value2) ? value2 : null)
    ;

    public override void ThrowScriptFailed(MigrationsFolder folder, string file, string? scriptText, Exception exception)
    {
        throw new OracleScriptFailed(folder, file, scriptText, exception);
    }
}
