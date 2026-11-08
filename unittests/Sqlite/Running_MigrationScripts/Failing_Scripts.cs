using Sqlite.TestInfrastructure;
using TestCommon.TestInfrastructure;

namespace Sqlite.Running_MigrationScripts;

[Collection(nameof(SqliteTestDatabase))]
// ReSharper disable once InconsistentNaming
// ReSharper disable once UnusedType.Global
public class Failing_Scripts(SqliteGrateTestContext testContext, ITestOutputHelper testOutput)
    : TestCommon.Generic.Running_MigrationScripts.Failing_Scripts(testContext, testOutput)
{
    protected override string ExpectedStartOfErrorMessageForInvalidSql =>
        """
        Update ("up"):
        --------------------------------------------------------------------------------
        2_failing.sql: SQLite Error 1: 'no such column: TOP'.
        """;

    // Sqlite does not provide the error detail in the Data collection as other databases do.
    // And, the error message basically contains all the details that are available as other properties
    // on the exception. So extracting a dictionary from explicit SqliteException properties does
    // not give us any more information than the message itself.
    protected override IDictionary<string, object?> ExpectedErrorDetails => new Dictionary<string, object?>()
    {
        { "Message", "SQLite Error 1: \u0027no such column: TOP\u0027." },
        { "Source", "Microsoft.Data.Sqlite" },
        { "SqliteErrorCode", 1 },
        { "SqliteExtendedErrorCode", 1 },
        { "IsTransient", false },
        { "HelpLink", null },
        { "HResult", -2147467259 },
    };


}
