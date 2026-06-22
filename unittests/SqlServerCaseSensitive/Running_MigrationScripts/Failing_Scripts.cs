using SqlServerCaseSensitive.TestInfrastructure;

namespace SqlServerCaseSensitive.Running_MigrationScripts;

[Collection(nameof(SqlServerCaseSensitiveGrateTestContext))]
// ReSharper disable once InconsistentNaming
public class Failing_Scripts(SqlServerCaseSensitiveGrateTestContext testContext, ITestOutputHelper testOutput)
    : TestCommon.Generic.Running_MigrationScripts.Failing_Scripts(testContext, testOutput)
{
    protected override string ExpectedStartOfErrorMessageForInvalidSql =>
        """
        Update ("up"):
        --------------------------------------------------------------------------------
        2_failing.sql: Incorrect syntax near 'TOP'.
        (0,0): SELECT TOP
              ^ Incorrect syntax near 'TOP'.
        """;

    protected override IDictionary<string, object?> ExpectedErrorDetails => new Dictionary<string, object?>
    {
        { "Message", "Incorrect syntax near \u0027TOP\u0027." },
        { "LineNumber", 1 },
        { "Number", 102 },
        { "Procedure", "" },
        { "Server", "localhost,59557" },
        { "Source", "Core Microsoft SqlClient Data Provider" },
        { "State", 1 },
        { "ClientConnectionId", "609b30bb-8410-43e7-93d8-69c84525c6cb" },
        { "Class", 15 },
        { "ErrorCode", -2146232060 },
        { "SqlState", 1 },
        { "IsTransient", false },
        { "HelpLink", null },
        { "HResult", -2146232060 },
    };
}
