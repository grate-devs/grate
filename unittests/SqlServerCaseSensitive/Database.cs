using SqlServerCaseSensitive.TestInfrastructure;
namespace SqlServerCaseSensitive;

[Collection(nameof(SqlServerCaseSensitiveGrateTestContext))]
public class Database(SqlServerCaseSensitiveGrateTestContext testContext, ITestOutputHelper testOutput)
    : TestCommon.Generic.GenericDatabase(testContext, testOutput);
