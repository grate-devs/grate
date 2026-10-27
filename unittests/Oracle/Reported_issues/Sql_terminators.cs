using Dapper;
using grate.Configuration;
using Oracle.TestInfrastructure;
using TestCommon.TestInfrastructure;

namespace Oracle.Reported_issues;

[Collection(nameof(OracleGrateTestContext))]
public sealed class Sql_terminators(OracleGrateTestContext testContext)
{
    private readonly IGrateTestContext _context = testContext;

    [Fact]
    public async Task Creates_the_actor_table_from_issue_283_with_a_trailing_semicolon()
    {
        var database = TestConfig.RandomDatabase();
        var directory = TestConfig.CreateRandomTempDirectory();
        var configuration = new GrateConfiguration
        {
            CreateDatabase = true,
            AdminConnectionString = _context.AdminConnectionString,
            ConnectionString = _context.ConnectionString(database),
            NonInteractive = true,
            SqlFilesDirectory = directory,
            OutputPath = new DirectoryInfo(Path.Combine(directory.FullName, "output")),
            Folders = Folders.Default
        };

        // Original reproduction from https://github.com/grate-devs/grate/issues/283.
        const string sql = """
            CREATE TABLE actor (
              actor_id numeric NOT NULL ,
              first_name VARCHAR(45) NOT NULL,
              last_name VARCHAR(45) NOT NULL,
              last_update DATE NOT NULL,
              CONSTRAINT pk_actor PRIMARY KEY  (actor_id)
            );
            """;
        TestConfig.WriteContent(TestConfig.Wrap(directory, "up"), "script0001.tables.sql", sql);

        try
        {
            await using (var migrator = _context.Migrator.WithConfiguration(configuration))
            {
                await migrator.Migrate();
            }

            using var connection = _context.CreateDbConnection(database);
            var tableCount = await connection.ExecuteScalarAsync<int>(
                "SELECT COUNT(*) FROM user_tables WHERE table_name = 'ACTOR'");
            Assert.Equal(1, tableCount);

            var primaryKey = await connection.QuerySingleAsync<string>(
                "SELECT constraint_name FROM user_constraints WHERE table_name = 'ACTOR' AND constraint_type = 'P'");
            Assert.Equal("PK_ACTOR", primaryKey);
        }
        finally
        {
            directory.Delete(recursive: true);
        }
    }
}
