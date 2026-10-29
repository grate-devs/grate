using grate.Configuration;
using grate.Infrastructure;
using grate.Migration;
using grate.Sqlite.Migration;
using Microsoft.Extensions.Logging;
using NSubstitute;

namespace Basic_tests.Infrastructure;

public record MockDbMigrator: IDbMigrator
{
    public ValueTask DisposeAsync() => ValueTask.CompletedTask;

    object ICloneable.Clone() => this with { };

    public GrateConfiguration Configuration { get; set; } = null!;
    
    public IDatabase Database { get; set; } = new MockDatabase();
    // This doesn't work in .NET 6 - so we must create an explicit implementation of IDatabase
    //public IDatabase Database { get; set; } = Substitute.For<IDatabase>();
    
    public ILogger Logger { get; set; } = Substitute.For<ILogger>();

    public  Task InitializeConnections()
    {
        return Task.CompletedTask;
    }

    public Task<bool> CreateDatabase()
    {
        return Task.FromResult(false);
    }

    public Task DropDatabase()
    {
        throw new NotImplementedException();
    }

    public Task<bool> DatabaseExists()
    {
        return Task.FromResult(false);
    }

    public Task OpenConnection()
    {
        throw new NotImplementedException();
    }

    public Task CloseConnection()
    {
        return Task.CompletedTask;
    }

    public Task RunSupportTasks()
    {
        return Task.CompletedTask;
    }

    public Task<string> GetCurrentVersion()
    {
        return Task.FromResult(string.Empty);
    }

    public Task<long> VersionTheDatabase(string newVersion)
    {
        return Task.FromResult(0L);
    }

    public Task OpenAdminConnection()
    {
        throw new NotImplementedException();
    }

    public Task CloseAdminConnection()
    {
        throw new NotImplementedException();
    }

    public virtual Task<(bool SqlRun, bool HistoryRecorded)> RunSql(string sql, string scriptName, MigrationsFolder folder, long versionId, GrateEnvironment? environment,
        ConnectionType connectionType, TransactionHandling transactionHandling)
    {
        return Task.FromResult((SqlRun: false, HistoryRecorded: false));
    }

    public virtual Task<bool> RunSqlWithoutLogging(string sql, string scriptName, GrateEnvironment? environment, ConnectionType connectionType,
        TransactionHandling transactionHandling)
    {
        throw new NotImplementedException();
    }

    public Task RestoreDatabase(string backupPath)
    {
        throw new NotImplementedException();
    }

    public void SetDefaultConnectionActive()
    {
        //throw new NotImplementedException();
    }

    public Task<IDisposable> OpenNewActiveConnection()
    {
        return Task.FromResult((IDisposable)null!);
    }

    public Task OpenActiveConnection()
    {
        return Task.CompletedTask;
    }
}
