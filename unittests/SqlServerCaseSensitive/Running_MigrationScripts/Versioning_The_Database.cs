using SqlServerCaseSensitive.TestInfrastructure;

namespace SqlServerCaseSensitive.Running_MigrationScripts;

[Collection(nameof(SqlServerCaseSensitiveGrateTestContext))]
// ReSharper disable once InconsistentNaming
public class Versioning_The_Database(SqlServerCaseSensitiveGrateTestContext testContext, ITestOutputHelper testOutput)
    : TestCommon.Generic.Running_MigrationScripts.Versioning_The_Database(testContext, testOutput);

