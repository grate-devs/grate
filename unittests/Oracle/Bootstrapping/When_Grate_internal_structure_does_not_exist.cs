using Oracle.TestInfrastructure;

namespace Oracle.Bootstrapping;

[Collection(nameof(OracleGrateTestContext))]
// ReSharper disable once InconsistentNaming
// ReSharper disable once UnusedType.Global
public class When_Grate_internal_structure_does_not_exist(OracleGrateTestContext context, ITestOutputHelper testOutput)
    : TestCommon.Generic.Bootstrapping.When_Grate_internal_structure_does_not_exist(context, testOutput);

