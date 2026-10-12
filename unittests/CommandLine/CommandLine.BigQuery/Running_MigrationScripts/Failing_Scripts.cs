using BigQuery.TestInfrastructure;
using TestCommon.TestInfrastructure;

namespace CommandLine.BigQuery.Running_MigrationScripts;

[Collection(nameof(BigQueryGrateTestContext))]
// ReSharper disable once InconsistentNaming
public class Failing_Scripts(BigQueryGrateTestContext testContext, ITestOutputHelper testOutput)
    : TestCommon.Generic.Running_MigrationScripts.Failing_Scripts(testContext, testOutput)
{
    protected override string ExpectedStartOfErrorMessageForInvalidSql => "Not relevant";
    protected override IDictionary<string, object?> ExpectedErrorDetails => new Dictionary<string, object?>();

    [Fact(Skip = "Cannot check on the exact error message when running the command line tool. The error message is not available.")]
    public override Task Aborts_the_run_giving_an_error_message() => Task.CompletedTask;
    
    [Fact(Skip = "Cannot check on the exact error details when running the command line tool. The error details are not available.")]
    public override Task Exception_includes_details_on_the_failed_script() => Task.CompletedTask;

    [Fact(Skip =
        "We do not have the ability to check for transient errors when running the command line tool. The error details are not available.")]
    public override Task Exception_is_set_to_transient_based_on_inner_exceptions() => Task.CompletedTask;

}
