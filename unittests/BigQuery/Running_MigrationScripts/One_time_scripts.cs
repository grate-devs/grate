using BigQuery.TestInfrastructure;
using TestCommon.TestInfrastructure;

namespace BigQuery.Running_MigrationScripts;

[Collection(nameof(BigQueryGrateTestContext))]
// ReSharper disable once InconsistentNaming
// ReSharper disable once UnusedType.Global
public class One_time_scripts(BigQueryGrateTestContext testContext, ITestOutputHelper testOutput)
    : TestCommon.Generic.Running_MigrationScripts.One_time_scripts(testContext, testOutput);
