using SqlServerCaseSensitive.TestInfrastructure;

namespace SqlServerCaseSensitive.Bootstrapping;

[Collection(nameof(SqlServerCaseSensitiveGrateTestContext))]
// ReSharper disable once InconsistentNaming
// ReSharper disable once UnusedType.Global
public class When_Grate_structure_does_not_exist(SqlServerCaseSensitiveGrateTestContext context, ITestOutputHelper testOutput)
    : TestCommon.Generic.Bootstrapping.When_Grate_structure_does_not_exist(context, testOutput);

