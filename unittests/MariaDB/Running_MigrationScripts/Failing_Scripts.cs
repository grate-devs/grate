using MariaDB.TestInfrastructure;
using TestCommon.TestInfrastructure;

namespace MariaDB.Running_MigrationScripts;

[Collection(nameof(MariaDbGrateTestContext))]
// ReSharper disable once InconsistentNaming
public class Failing_Scripts(MariaDbGrateTestContext testContext, ITestOutputHelper testOutput)
    : TestCommon.Generic.Running_MigrationScripts.Failing_Scripts(testContext, testOutput)
{
    protected override string ExpectedStartOfErrorMessageForInvalidSql =>
        """
        Update ("up"):
        --------------------------------------------------------------------------------
        2_failing.sql: Unknown column 'TOP' in 'field list'
        """;


    protected override IDictionary<string, object?> ExpectedErrorDetails => new Dictionary<string, object?>
    {
        {"Server Error Code", 1054},
        {"SqlState", "42S22"}
    };
}
