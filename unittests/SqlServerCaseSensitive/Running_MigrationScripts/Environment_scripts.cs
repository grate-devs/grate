using SqlServerCaseSensitive.TestInfrastructure;

namespace SqlServerCaseSensitive.Running_MigrationScripts;

[Collection(nameof(SqlServerCaseSensitiveGrateTestContext))]
// ReSharper disable once InconsistentNaming
public class Environment_scripts(SqlServerCaseSensitiveGrateTestContext testContext, ITestOutputHelper testOutput)
    : TestCommon.Generic.Running_MigrationScripts.Environment_scripts(testContext, testOutput);
