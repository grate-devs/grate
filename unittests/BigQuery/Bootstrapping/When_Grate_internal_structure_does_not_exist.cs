using BigQuery.TestInfrastructure;
using TestCommon.TestInfrastructure;

namespace BigQuery.Bootstrapping;

[Collection(nameof(BigQueryGrateTestContext))]
// ReSharper disable once InconsistentNaming
// ReSharper disable once UnusedType.Global
public class When_Grate_internal_structure_does_not_exist(BigQueryGrateTestContext context, ITestOutputHelper testOutput)
    : TestCommon.Generic.Bootstrapping.When_Grate_internal_structure_does_not_exist(context, testOutput)
{
    [Fact(Skip = "The BigQuery emulator answers CREATE SCHEMA without creating the dataset")]
    public override Task GrateScriptsRun_table_is_created_even_with_custom_create_database_script() => Task.CompletedTask;
}

