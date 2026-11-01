using Dapper;
using grate.Configuration;
using Oracle.TestInfrastructure;
using TestCommon.TestInfrastructure;

namespace Oracle.Reported_issues;

[Collection(nameof(OracleGrateTestContext))]
public sealed class Case_expressions(OracleGrateTestContext testContext)
{
    private readonly IGrateTestContext _context = testContext;

    [Fact]
    public async Task Executes_anonymous_case_expression_and_the_following_sql_command()
    {
        const string sql = """
            DECLARE
                value NUMBER;
            BEGIN
                value := CASE WHEN 1 = 1 THEN 1 ELSE 0 END;
                NULL;
                INSERT INTO case_results (result) VALUES (value);
            END;
            /
            INSERT INTO case_results (result) VALUES (2);
            """;

        var results = await MigrateAndReadResults(sql);
        Assert.Equal([1, 2], results);
    }

    [Fact]
    public async Task Executes_local_function_with_unnamed_end_and_the_following_sql_command()
    {
        const string sql = """
            DECLARE
                value NUMBER;
                FUNCTION twice(n NUMBER) RETURN NUMBER IS
                BEGIN
                    RETURN n * 2;
                END;
            BEGIN
                value := twice(2);
                INSERT INTO case_results (result) VALUES (value);
            END;
            /
            INSERT INTO case_results (result) VALUES (5);
            """;

        var results = await MigrateAndReadResults(sql);
        Assert.Equal([4, 5], results);
    }

    [Fact]
    public async Task Executes_identifier_containing_end_and_the_following_sql_command()
    {
        const string sql = """
            DECLARE
                amount$END NUMBER := 3;
                value NUMBER;
            BEGIN
                value := amount$END;
                INSERT INTO case_results (result) VALUES (value);
            END;
            /
            INSERT INTO case_results (result) VALUES (4);
            """;

        var results = await MigrateAndReadResults(sql);
        Assert.Equal([3, 4], results);
    }

    [Fact]
    public async Task Executes_inline_with_function_and_the_following_sql_command()
    {
        const string sql = """
            INSERT /*+ WITH_PLSQL */ INTO case_results (result)
            WITH
                FUNCTION get_number RETURN NUMBER IS
                BEGIN
                    RETURN 6;
                END;
            SELECT get_number FROM dual;
            /
            INSERT INTO case_results (result) VALUES (7);
            """;

        var results = await MigrateAndReadResults(sql);
        Assert.Equal([6, 7], results);
    }

    private async Task<int[]> MigrateAndReadResults(string sql)
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
        TestConfig.WriteContent(TestConfig.Wrap(directory, "up"), "001_case_expression.sql",
            "CREATE TABLE case_results (result NUMBER NOT NULL);\n" + sql);

        try
        {
            await using (var migrator = _context.Migrator.WithConfiguration(configuration))
            {
                await migrator.Migrate();
            }

            using var connection = _context.CreateDbConnection(database);
            return (await connection.QueryAsync<int>(
                "SELECT result FROM case_results ORDER BY result")).ToArray();
        }
        finally
        {
            directory.Delete(recursive: true);
        }
    }
}
