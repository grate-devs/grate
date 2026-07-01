using SqlServer.TestInfrastructure;
using TestCommon.TestInfrastructure;

namespace SqlServer;

[Collection(nameof(SqlServerGrateTestContext))]
public class Database(SqlServerGrateTestContext testContext, ITestOutputHelper testOutput)
    : TestCommon.Generic.GenericDatabase(testContext, testOutput)
{
  
    [Fact]
    public async Task Does_not_needlessly_apply_case_sensitive_database_name_checks_Issue_167()
    {
        // There's a bug where if the database name specified by the user differs from the actual database only by case then
        // Grate currently attempts to create the database again, only for it to fail on the DBMS (Sql Server, case insensitive  bug only).

        var db = "CASEDATABASE";
        await CreateDatabase(db);

        // Check that the database has been created
        IEnumerable<string> databasesBeforeMigration = await GetDatabases();
        Assert.Contains(db, databasesBeforeMigration);
        
        // ToLower is important here, this reproduces the bug in #167
        await using var migrator = GetMigrator(GetConfiguration(db.ToLower(), true));
        // There should be no errors running the migration
        Action action = () => migrator.Migrate();
        Assert.Null(Record.Exception(action));
    }
}
