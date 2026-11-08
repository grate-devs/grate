using PostgreSQL.TestInfrastructure;
using TestCommon.TestInfrastructure;

namespace PostgreSQL.Running_MigrationScripts;

[Collection(nameof(PostgreSqlGrateTestContext))]
// ReSharper disable once InconsistentNaming
public class Failing_Scripts(PostgreSqlGrateTestContext testContext, ITestOutputHelper testOutput)
    : TestCommon.Generic.Running_MigrationScripts.Failing_Scripts(testContext, testOutput)
{

    protected override string ExpectedStartOfErrorMessageForInvalidSql =>
        """
        Update ("up"):
        --------------------------------------------------------------------------------
        2_failing.sql: 42703: column "top" does not exist
        (0,8): SELECT TOP
                      ^ 42703: column "top" does not exist
        """;


    protected override IDictionary<string, object?> ExpectedErrorDetails => new Dictionary<string, object?>
    {
        {"Severity", "ERROR"},
        {"InvariantSeverity", "ERROR"},
        {"SqlState", "42703"},
        {"MessageText", "column \"top\" does not exist"},
        {"Position", 8},
        {"File", "parse_relation.c"},
        // The line is PostgreSQL version specific, so it doesn't make sense to check it.
        //{"Line", "3713"},
        {"Routine", "errorMissingColumn"}
    };
}
