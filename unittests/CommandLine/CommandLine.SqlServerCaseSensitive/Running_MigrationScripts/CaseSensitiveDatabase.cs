using Dapper;
using Microsoft.Data.SqlClient;
using SqlServerCaseSensitive.TestInfrastructure;
using TestCommon.TestInfrastructure;

namespace CommandLine.SqlServerCaseSensitive.Running_MigrationScripts;

[Collection(nameof(SqlServerCaseSensitiveGrateTestContext))]
public sealed class CaseSensitiveDatabase(SqlServerCaseSensitiveGrateTestContext testContext)
{
    [Fact]
    public async Task Cli_creates_a_case_sensitive_database_and_records_the_migration_once()
    {
        IGrateTestContext context = testContext;
        var database = TestConfig.RandomDatabase();
        var configuration = context.DefaultConfiguration;
        var directory = configuration.OutputPath;
        try
        {
            var scripts = directory.CreateSubdirectory("sql");
            var up = scripts.CreateSubdirectory("up");
            await File.WriteAllTextAsync(Path.Combine(up.FullName, "001_case_sensitive.sql"),
                """
                CREATE TABLE dbo.CaseSensitiveProbe (id int PRIMARY KEY, payload nvarchar(50) NOT NULL);
                INSERT INTO dbo.CaseSensitiveProbe VALUES (1, 'Case-sensitive CLI');
                """, TestContext.Current.CancellationToken);
            configuration = configuration with
            {
                ConnectionString = context.ConnectionString(database),
                SqlFilesDirectory = scripts
            };

            await using (var migrator = context.Migrator.WithConfiguration(configuration))
            {
                await migrator.Migrate();
                await migrator.Migrate();
            }

            using var connection = context.CreateDbConnection(database);
            var collation = await connection.QuerySingleAsync<string>(
                "SELECT CAST(DATABASEPROPERTYEX(DB_NAME(), 'Collation') AS nvarchar(128))");
            Assert.Equal("Danish_Norwegian_CS_AS", collation);
            Assert.Equal("Case-sensitive CLI", await connection.QuerySingleAsync<string>(
                "SELECT payload FROM dbo.CaseSensitiveProbe WHERE id = 1"));
            var wrongCase = await Assert.ThrowsAsync<SqlException>(() => connection.QuerySingleAsync<int>(
                "SELECT COUNT(*) FROM dbo.casesensitiveprobe"));
            Assert.Equal(208, wrongCase.Number);
            var scriptsRun = context.Syntax.TableWithSchema("grate", "ScriptsRun");
            Assert.Equal(1, await connection.QuerySingleAsync<int>(
                $"SELECT COUNT(*) FROM {scriptsRun} WHERE script_name = @script",
                new { script = "001_case_sensitive.sql" }));
            var errors = context.Syntax.TableWithSchema("grate", "ScriptsRunErrors");
            Assert.Equal(0, await connection.QuerySingleAsync<int>($"SELECT COUNT(*) FROM {errors}"));
        }
        finally
        {
            try
            {
                await context.DropDatabase(database);
            }
            finally
            {
                directory.Delete(recursive: true);
            }
        }
    }
}
