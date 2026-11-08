using Sqlite.TestInfrastructure;
using TestCommon.TestInfrastructure;
using static TestCommon.TestInfrastructure.DatabaseHelpers;

namespace Sqlite.Running_MigrationScripts;

[Collection(nameof(SqliteTestDatabase))]
// ReSharper disable once InconsistentNaming
// ReSharper disable once UnusedType.Global
public class Run_After_Create_Database_scripts(SqliteGrateTestContext testContext, ITestOutputHelper testOutput)
    : TestCommon.Generic.Running_MigrationScripts.Run_After_Create_Database_scripts(testContext, testOutput)
{
    [Fact(Skip = "Sqlite does not support creating databases using grate")]
    public override Task Are_run_if_the_database_is_created_from_scratch() => Task.CompletedTask;

    protected override Task<IEnumerable<string>> GetDatabases() => Context.GetSqliteDatabases();

    protected override Task CreateDatabaseFromConnectionString(string db, string connectionString)
        => CreateSqliteDatabaseFromConnectionString(connectionString);
}
