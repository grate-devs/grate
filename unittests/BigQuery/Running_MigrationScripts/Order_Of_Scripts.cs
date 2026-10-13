using BigQuery.TestInfrastructure;
using TestCommon.TestInfrastructure;

namespace BigQuery.Running_MigrationScripts;

[Collection(nameof(BigQueryGrateTestContext))]
// ReSharper disable once InconsistentNaming
// ReSharper disable once UnusedType.Global
public class Order_Of_Scripts(BigQueryGrateTestContext testContext, ITestOutputHelper testOutput)
    : TestCommon.Generic.Running_MigrationScripts.Order_Of_Scripts(testContext, testOutput);
