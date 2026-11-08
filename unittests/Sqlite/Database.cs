using Sqlite.TestInfrastructure;
using TestCommon.TestInfrastructure;
using static TestCommon.TestInfrastructure.DatabaseHelpers;

namespace Sqlite;

[Collection(nameof(SqliteTestDatabase))]
// ReSharper disable once InconsistentNaming
// ReSharper disable once UnusedType.Global
public class Database(SqliteGrateTestContext testContext, ITestOutputHelper testOutput)
    : TestCommon.Generic.GenericDatabase(testContext, testOutput)
{

    protected override Task CreateDatabaseFromConnectionString(string db, string connectionString)
        => CreateSqliteDatabaseFromConnectionString(connectionString);

    protected override Task<IEnumerable<string>> GetDatabases()
        => Context.GetSqliteDatabases();

    [Fact(Skip = "SQLite does not support custom database creation script")]
    public override Task Is_created_with_custom_script_if_custom_create_database_folder_exists() =>
        Task.CompletedTask;

    [Fact(Skip = "SQLite does not support docker container")]
    public override Task Is_up_and_running_with_appropriate_database_version() => Task.CompletedTask;
    protected override bool ThrowOnMissingDatabase => false;

}
