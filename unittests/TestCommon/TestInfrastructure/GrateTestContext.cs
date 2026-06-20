using System.Data;
using System.Diagnostics.CodeAnalysis;
using Dapper;
using grate.Infrastructure;
using grate.Migration;

namespace TestCommon.TestInfrastructure;

public abstract record GrateTestContext(IGrateMigrator Migrator, ITestDatabase TestDatabase) : IGrateTestContext, IAsyncLifetime
{
    //public IGrateMigrator Migrator { get; } = Migrator;
    //protected ITestDatabase TestDatabase { get; } = TestDatabase;

    public string AdminConnectionString => TestDatabase.AdminConnectionString;
    public string ConnectionString(string database) => TestDatabase.ConnectionString(database);
    public string UserConnectionString(string database) => TestDatabase.UserConnectionString(database);

    public virtual IGrateTestContext External => this with { TestDatabase = TestDatabase.External };
    
    public async ValueTask InitializeAsync()
    {
        if (TestDatabase is IAsyncLifetime asyncLifetime)
        {
            await asyncLifetime.InitializeAsync();
        }
    }

    public async ValueTask DisposeAsync()
    {
        if (TestDatabase is IAsyncLifetime asyncLifetime)
        {
            await asyncLifetime.DisposeAsync();
        }
    }
    
    public async Task DropDatabase(string databaseName)
    {
        var sql = Syntax.DropDatabase(databaseName);
        using var conn = GetDbConnection(AdminConnectionString);
        await conn.ExecuteAsync(sql);
    }

    public abstract ISyntax Syntax { get; }
    public abstract Type DbExceptionType { get; }
    
    public abstract Type DatabaseType { get; }
    
    public abstract bool SupportsTransaction { get; }
    public abstract SqlStatements Sql { get; }
    public abstract string ExpectedVersionPrefix { get; }
    public abstract bool SupportsCreateDatabase { get; }
    public abstract bool SupportsSchemas { get; }
    public abstract IDbConnection GetDbConnection(string connectionString);


}
