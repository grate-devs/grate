using SqlServerCaseSensitive.TestInfrastructure;

namespace SqlServerCaseSensitive.Bootstrapping;

[Collection(nameof(SqlServerCaseSensitiveGrateTestContext))]
// ReSharper disable once InconsistentNaming
// ReSharper disable once UnusedType.Global
public class Grate_Internal_Scripts(SqlServerCaseSensitiveGrateTestContext testContext, ITestOutputHelper testOutput)
    : TestCommon.Generic.Bootstrapping.Grate_Internal_Scripts(testContext, testOutput);
