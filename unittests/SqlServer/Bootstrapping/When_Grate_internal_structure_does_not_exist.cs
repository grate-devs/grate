using SqlServer.TestInfrastructure;

namespace SqlServer.Bootstrapping;

[Collection(nameof(SqlServerGrateTestContext))]
// ReSharper disable once InconsistentNaming
// ReSharper disable once UnusedType.Global
public class When_Grate_internal_structure_does_not_exist(SqlServerGrateTestContext context, ITestOutputHelper testOutput)
    : TestCommon.Generic.Bootstrapping.When_Grate_internal_structure_does_not_exist(context, testOutput);

