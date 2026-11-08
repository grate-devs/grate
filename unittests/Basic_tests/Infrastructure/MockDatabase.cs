using System.Data.Common;
using grate.Configuration;
using grate.Migration;
using Microsoft.Extensions.Logging;

namespace Basic_tests.Infrastructure;

public record MockDatabase : IDatabase
{
    public ValueTask DisposeAsync() => ValueTask.CompletedTask;

    object ICloneable.Clone() => this with { };

    public string? ServerName { get; set; }
    public string? DatabaseName { get; set; }
    public string DatabaseType { get; } = "Mock";
    public string MasterDatabaseName { get; } = "Mock";
    public bool SupportsDdlTransactions { get; set; }
    public bool SplitBatchStatements { get; set; }
    public string ScriptsRunTable { get; } = "ScriptsRun";
    public string ScriptsRunErrorsTable { get; } = "ScriptsRunErrors";
    public string VersionTable { get; } = "Version";
    public DbConnection ActiveConnection { get; set; } = null!;
    public bool SupportsSchemas { get; set; }
    public Task InitializeConnections(GrateConfiguration configuration) => Task.CompletedTask;

    public Task OpenConnection() => Task.CompletedTask;
    public Task CloseConnection() => Task.CompletedTask;
    public Task OpenAdminConnection() => Task.CompletedTask;
    public Task CloseAdminConnection() => Task.CompletedTask;
    public Task CreateDatabase() => Task.CompletedTask;
    public Task RestoreDatabase(string backupPath) => Task.CompletedTask;
    public void SetLogger(ILogger logger) { }
    public Task DropDatabase() => Task.CompletedTask;
    public Task<bool> DatabaseExists() => Task.FromResult(false);
    public Task<string> GetCurrentVersion() => Task.FromResult(string.Empty);
    public Task<long> VersionTheDatabase(string newVersion) => Task.FromResult(0L);
    public void Rollback() { }

    public Task RunSql(string sql, ConnectionType connectionType, TransactionHandling transactionHandling) => Task.CompletedTask;
    public Task<string?> GetCurrentHash(string scriptName) => Task.FromResult(string.Empty)!;
    public Task<bool> HasRun(string scriptName, TransactionHandling transactionHandling) => Task.FromResult(false);
    public Task InsertScriptRun(string scriptName, string? sql, string hash, bool runOnce, long versionId,
        TransactionHandling transactionHandling) => Task.CompletedTask;

    public Task InsertScriptRunError(string scriptName, string? sql, string errorSql, string errorMessage, long versionId) => Task.CompletedTask;

    public Task<bool> VersionTableExists() => Task.FromResult(false);

    public Task<bool> GrateInternalTablesAreProperlyLogged() => Task.FromResult(false);

    public Task ChangeVersionStatus(string status, long versionId) => Task.CompletedTask;

    public Task DeleteVersionRecord(long versionId) => Task.CompletedTask;

    public void SetDefaultConnectionActive() { }

    public Task<IDisposable> OpenNewActiveConnection() => Task.FromResult<IDisposable>(new HttpClient());

    public Task OpenActiveConnection() => Task.CompletedTask;
    public Task<string?> ExistingTable(string schemaName, string tableName) => Task.FromResult(string.Empty)!;

    public IEnumerable<string> GetStatements(string sql) => new List<string>();
    public void ThrowScriptFailed(MigrationsFolder folder, string file, string? scriptText, Exception exception) { }

}
