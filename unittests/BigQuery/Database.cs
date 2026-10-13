using BigQuery.TestInfrastructure;
using TestCommon.TestInfrastructure;

namespace BigQuery;

[Collection(nameof(BigQueryGrateTestContext))]
// ReSharper disable once InconsistentNaming
// ReSharper disable once UnusedType.Global
public class Database(BigQueryGrateTestContext testContext, ITestOutputHelper testOutput)
    : TestCommon.Generic.GenericDatabase(testContext, testOutput)
{
    protected override Task CreateDatabaseFromConnectionString(string db, string connectionString)
        => BigQueryDatabaseHelpers.CreateBigQueryDatabaseFromConnectionString(connectionString);

    protected override Task<IEnumerable<string>> GetDatabases() => Context.GetBigQueryDatabases();

    [Fact(Skip = "BigQuery has no version to select")]
    public override Task Is_up_and_running_with_appropriate_database_version() => Task.CompletedTask;

    [Fact(Skip = "The BigQuery emulator answers CREATE SCHEMA without creating the dataset")]
    public override Task Is_created_with_custom_script_if_custom_create_database_folder_exists() => Task.CompletedTask;
}
