using Dapper;
using grate.Configuration;
using grate.Exceptions;
using Oracle.ManagedDataAccess.Client;
using Oracle.TestInfrastructure;
using TestCommon.TestInfrastructure;

namespace Oracle.Running_MigrationScripts;

[Collection(nameof(OracleGrateTestContext))]
public class Failing_Scripts(OracleGrateTestContext testContext, ITestOutputHelper testOutput)
    : TestCommon.Generic.Running_MigrationScripts.Failing_Scripts(testContext, testOutput)
{
    protected override void AssertScriptTimeoutCause(MigrationFailed exception)
    {
        var failure = Assert.Single(exception.InnerExceptions);
        if (failure is ScriptFailed failedScript)
        {
            Assert.Equal("goodnight.sql", failedScript.File);
        }
        else
        {
            // The managed driver's async command path wraps Oracle cancellation.
            Assert.IsAssignableFrom<OperationCanceledException>(failure);
        }

        var cause = failure;
        while (cause is not OracleException && cause.InnerException is { } inner)
        {
            cause = inner;
        }
        Assert.Equal(1013, Assert.IsType<OracleException>(cause).Number);
    }

    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public async Task Sleep_script_completes_when_timeout_allows_execution(bool adminConnection)
    {
        var db = TestConfig.RandomDatabase();
        var root = CreateRandomTempDirectory();
        var folders = Folders.Default;
        var folder = folders[adminConnection ? KnownFolderKeys.AlterDatabase : KnownFolderKeys.Up];
        var path = MakeSurePathExists(root, folder);
        var config = GrateConfigurationBuilder.Create(Context.DefaultConfiguration)
            .WithConnectionString(Context.ConnectionString(db))
            .WithSqlFilesDirectory(root)
            .Build() with
        {
            CommandTimeout = 10,
            AdminCommandTimeout = 10
        };

        await using (var setup = Context.Migrator.WithConfiguration(config))
        {
            await setup.Migrate();
        }

        WriteSql(path, "goodnight.sql", Context.Sql.SleepTwoSeconds);
        await using (var migrator = Context.Migrator.WithConfiguration(config with { CreateDatabase = false }))
        {
            await migrator.Migrate();
        }

        using var connection = Context.External.CreateDbConnection(db);
        var errorTable = Context.Syntax.TableWithSchema(config.SchemaName, config.ScriptsRunErrorsTableName);
        var successTable = Context.Syntax.TableWithSchema(config.SchemaName, config.ScriptsRunTableName);
        var failedScripts = await connection.QueryAsync<string>($"SELECT script_name FROM {errorTable}");
        var successfulScripts = await connection.QueryAsync<string>($"SELECT script_name FROM {successTable}");
        Assert.Empty(failedScripts);
        Assert.Equal("goodnight.sql", Assert.Single(successfulScripts));
    }

    protected override string ExpectedStartOfErrorMessageForInvalidSql =>
"""
Update ("up"):
--------------------------------------------------------------------------------
2_failing.sql: ORA-
""";

    protected override IDictionary<string, object?> ExpectedErrorDetails => new Dictionary<string, object?>
    {
        {"Message", "ORA-00923: FROM keyword not found where expected"},
        {"ParseErrorOffset", 10},
        {"Number", 923},
        {"Procedure", ""},
        {"DataSource", ""},
        {"Source", "Oracle Data Provider for .NET, Managed Driver"},
        {"ErrorCode", -2147467259},
        {"IsTransient", false},
        {"HelpLink", null},
        {"HResult", -2147467259},
    };
}
