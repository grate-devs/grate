using Oracle.TestInfrastructure;

namespace Oracle.Bootstrapping;

[Collection(nameof(OracleGrateTestContext))]
// ReSharper disable once InconsistentNaming
// ReSharper disable once UnusedType.Global
public class When_Grate_structure_is_not_latest_version(OracleGrateTestContext context, ITestOutputHelper testOutput)
    : TestCommon.Generic.Bootstrapping.When_Grate_structure_is_not_latest_version(context, testOutput);

