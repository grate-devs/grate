using BigQuery.TestInfrastructure;
using TestCommon.TestInfrastructure;

namespace BigQuery.Running_MigrationScripts;

[Collection(nameof(BigQueryGrateTestContext))]
// ReSharper disable once InconsistentNaming
// ReSharper disable once UnusedType.Global
public class Run_After_Create_Database_scripts(BigQueryGrateTestContext testContext, ITestOutputHelper testOutput)
    : TestCommon.Generic.Running_MigrationScripts.Run_After_Create_Database_scripts(testContext, testOutput)
{
    protected override Task<IEnumerable<string>> GetDatabases() => Context.GetBigQueryDatabases();

    protected override Task CreateDatabaseFromConnectionString(string db, string connectionString)
        => BigQueryDatabaseHelpers.CreateBigQueryDatabaseFromConnectionString(connectionString);
}
