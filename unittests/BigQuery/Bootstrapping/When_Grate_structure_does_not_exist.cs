using BigQuery.TestInfrastructure;
using TestCommon.TestInfrastructure;

namespace BigQuery.Bootstrapping;

[Collection(nameof(BigQueryGrateTestContext))]
// ReSharper disable once InconsistentNaming
// ReSharper disable once UnusedType.Global
public class When_Grate_structure_does_not_exist(BigQueryGrateTestContext context, ITestOutputHelper testOutput) 
    : TestCommon.Generic.Bootstrapping.When_Grate_structure_does_not_exist(context, testOutput);

