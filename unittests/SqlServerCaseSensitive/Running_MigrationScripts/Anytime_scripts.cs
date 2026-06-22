using SqlServerCaseSensitive.TestInfrastructure;

namespace SqlServerCaseSensitive.Running_MigrationScripts;

[Collection(nameof(SqlServerCaseSensitiveGrateTestContext))]
// ReSharper disable once InconsistentNaming
public class Anytime_scripts(SqlServerCaseSensitiveGrateTestContext testContext, ITestOutputHelper testOutput)
    : TestCommon.Generic.Running_MigrationScripts.Anytime_scripts(testContext, testOutput);

