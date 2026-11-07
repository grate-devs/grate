using MariaDB.TestInfrastructure;

namespace MariaDB.Bootstrapping;

[Collection(nameof(MariaDbGrateTestContext))]
// ReSharper disable once InconsistentNaming
// ReSharper disable once UnusedType.Global
public class When_Grate_internal_structure_does_not_exist(MariaDbGrateTestContext context, ITestOutputHelper testOutput)
    : TestCommon.Generic.Bootstrapping.When_Grate_internal_structure_does_not_exist(context, testOutput);

