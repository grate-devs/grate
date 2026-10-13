using BigQuery.TestInfrastructure;
using TestCommon.TestInfrastructure;

namespace BigQuery.Running_MigrationScripts;

[Collection(nameof(BigQueryGrateTestContext))]
// ReSharper disable once InconsistentNaming
// ReSharper disable once UnusedType.Global
public class Failing_Scripts(BigQueryGrateTestContext testContext, ITestOutputHelper testOutput)
    : TestCommon.Generic.Running_MigrationScripts.Failing_Scripts(testContext, testOutput)
{
    // the text of a syntax error differs between BigQuery and the emulator, so only the failed script is asserted
    protected override string ExpectedStartOfErrorMessageForInvalidSql =>
        """
        Update ("up"):
        --------------------------------------------------------------------------------
        2_failing.sql:
        """;

    protected override IDictionary<string, object?> ExpectedErrorDetails => new Dictionary<string, object?>
    {
        { "Message", null },
        { "HttpStatusCode", 400 },
        { "Reason", "invalidQuery" },
        { "Location", null },
        { "Errors", null },
    };
}
