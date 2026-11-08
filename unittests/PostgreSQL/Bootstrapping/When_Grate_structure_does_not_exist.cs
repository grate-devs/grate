using PostgreSQL.TestInfrastructure;

namespace PostgreSQL.Bootstrapping;

[Collection(nameof(PostgreSqlGrateTestContext))]
// ReSharper disable once InconsistentNaming
// ReSharper disable once UnusedType.Global
public class When_Grate_structure_does_not_exist(PostgreSqlGrateTestContext context, ITestOutputHelper testOutput)
    : TestCommon.Generic.Bootstrapping.When_Grate_structure_does_not_exist(context, testOutput);

