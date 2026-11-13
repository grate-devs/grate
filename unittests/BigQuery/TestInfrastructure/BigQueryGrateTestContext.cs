using System.Data;
using BigQuery.TestInfrastructure.AdoNet;
using grate.BigQuery.Infrastructure;
using grate.BigQuery.Migration;
using grate.Infrastructure;
using grate.Migration;
using TestCommon.TestInfrastructure;

namespace BigQuery.TestInfrastructure;

[CollectionDefinition(nameof(BigQueryGrateTestContext))]
public class BigQueryTestCollection : ICollectionFixture<BigQueryGrateTestContext>;

/// <summary>
/// BigQuery for grate's shared tests. The tests read grate's tables through Dapper, and BigQuery has no ADO.NET
/// provider, so the connection is a small adapter over the BigQuery client - for the tests only.
/// </summary>
public record BigQueryGrateTestContext(IGrateMigrator Migrator, ITestDatabase TestDatabase) : IGrateTestContext, IAsyncLifetime
{
    public string AdminConnectionString => TestDatabase.AdminConnectionString;
    public string ConnectionString(string database) => TestDatabase.ConnectionString(database);
    public string UserConnectionString(string database) => TestDatabase.UserConnectionString(database);

    public IGrateTestContext External => this with { TestDatabase = TestDatabase.External };

    public IDbConnection GetDbConnection(string connectionString) => new BigQueryTestConnection(connectionString);

    public ISyntax Syntax => BigQueryDatabase.Syntax;
    public Type DbExceptionType => typeof(BigQueryDbException);
    public Type DatabaseType => typeof(BigQueryDatabase);
    public bool SupportsTransaction => false;

    public SqlStatements Sql => new()
    {
        SelectVersion = "SELECT 'BigQuery'",
    };

    public string ExpectedVersionPrefix => throw new NotSupportedException("BigQuery has no version to select");
    public bool SupportsCreateDatabase => true;
    public bool SupportsSchemas => false;

    // a dataset is dropped through the API - the emulator does not run DROP SCHEMA
    public Task DropDatabase(string databaseName) => BigQueryDatabaseHelpers.DropDataset(ConnectionString(databaseName));

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

        GC.SuppressFinalize(this);
    }
}
