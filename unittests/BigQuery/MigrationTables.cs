using BigQuery.TestInfrastructure;
using TestCommon.TestInfrastructure;

namespace BigQuery;

[Collection(nameof(BigQueryGrateTestContext))]
// ReSharper disable once InconsistentNaming
// ReSharper disable once UnusedType.Global
public class MigrationTables(BigQueryGrateTestContext testContext, ITestOutputHelper testOutput)
    : TestCommon.Generic.GenericMigrationTables(testContext, testOutput)
{
    // the connection's default dataset is the database, and the table name already has its {schema}_ prefix
    protected override string CountTableSql(string schemaName, string tableName) =>
        $"SELECT COUNT(*) FROM INFORMATION_SCHEMA.TABLES WHERE table_name = '{tableName}'";
}
