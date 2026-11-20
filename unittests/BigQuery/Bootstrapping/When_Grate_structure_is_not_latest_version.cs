using grate.Configuration;
using BigQuery.TestInfrastructure;
using TestCommon.TestInfrastructure;

namespace BigQuery.Bootstrapping;

[Collection(nameof(BigQueryGrateTestContext))]
// ReSharper disable once InconsistentNaming
// ReSharper disable once UnusedType.Global
public class When_Grate_structure_is_not_latest_version(BigQueryGrateTestContext context, ITestOutputHelper testOutput)
    : TestCommon.Generic.Bootstrapping.When_Grate_structure_is_not_latest_version(context, testOutput)
{
    // The old structure these tests build - a version table without the status column - never existed in
    // BigQuery, as the provider has always created grate's tables with it
#pragma warning disable xUnit1026 // skipped theories - the parameters only match the base class's
    [Theory(Skip = "BigQuery has no tables from before the status column, so it has no upgrade scripts")]
    [InlineData("version")]
    public override Task The_latest_version_is_applied(string versionTableName) => Task.CompletedTask;

    [Theory(Skip = "BigQuery has no tables from before the status column, so it has no upgrade scripts")]
    [InlineData("scriptsrun", "scriptsrunerrors", "version")]
    public override Task The_table_name_casings_are_converted_if_needed(string scriptsRun, string scriptsRunErrors, string version) =>
        Task.CompletedTask;
#pragma warning restore xUnit1026
}

