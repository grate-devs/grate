using BigQuery.TestInfrastructure;

namespace BigQuery.Reported_issues.Reported_issues.Non_ascii_characters_in_script;

[Collection(nameof(BigQueryGrateTestContext))]
// ReSharper disable once InconsistentNaming
public class ScriptsRunErrorsTable(BigQueryGrateTestContext testContext, ITestOutputHelper testOutput)
    : TestCommon.Generic.Reported_issues.Non_ascii_characters_in_script.ScriptsRunErrorsTable(testContext, testOutput);

