using grate.Configuration;
using BigQuery.TestInfrastructure;
using TestCommon.TestInfrastructure;

namespace BigQuery.Running_MigrationScripts;

[Collection(nameof(BigQueryGrateTestContext))]
// ReSharper disable once InconsistentNaming
// ReSharper disable once UnusedType.Global
public class Versioning_The_Database(BigQueryGrateTestContext testContext, ITestOutputHelper testOutput)
    : TestCommon.Generic.Running_MigrationScripts.Versioning_The_Database(testContext, testOutput);

