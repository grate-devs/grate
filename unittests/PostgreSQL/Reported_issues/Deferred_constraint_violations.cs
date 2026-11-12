using Dapper;
using grate.Configuration;
using grate.Migration;
using Npgsql;
using PostgreSQL.TestInfrastructure;
using TestCommon.TestInfrastructure;

namespace PostgreSQL.Reported_issues;

[Collection(nameof(PostgreSqlGrateTestContext))]
public sealed class Deferred_constraint_violations(PostgreSqlGrateTestContext context) : IDisposable
{
    private readonly DirectoryInfo _root = Directory.CreateTempSubdirectory("grate-deferred-constraint-");

    [Fact]
    public async Task Failed_commit_reports_an_error_and_rolls_back_transactional_scripts_and_history()
    {
        var database = TestConfig.RandomDatabase();
        WriteScript("up", "001_parent.sql", "CREATE TABLE parent (id integer PRIMARY KEY);");
        WriteScript("up", "002_child.sql", """
            CREATE TABLE child (
                parent_id integer REFERENCES parent(id) DEFERRABLE INITIALLY DEFERRED
            );
            INSERT INTO child (parent_id) VALUES (42);
            """);
        WriteScript("permissions", "003_permissions.sql", "CREATE TABLE permissions_marker (id integer);");
        var config = context.Migrator.Configuration with
        {
            ConnectionString = context.ConnectionString(database),
            AdminConnectionString = context.AdminConnectionString,
            SqlFilesDirectory = _root,
            OutputPath = _root.CreateSubdirectory("output"),
            Folders = Folders.Default,
            Transaction = true,
            NonInteractive = true,
            CreateDatabase = true
        };

        try
        {
            Exception? error;
            await using (var migrator = context.Migrator.WithConfiguration(config))
            {
                error = await Record.ExceptionAsync(migrator.Migrate);
            }

            using var connection = context.External.CreateDbConnection(database);
            Assert.False(await connection.QuerySingleAsync<bool>("SELECT to_regclass('public.parent') IS NOT NULL"));
            Assert.False(await connection.QuerySingleAsync<bool>("SELECT to_regclass('public.child') IS NOT NULL"));
            Assert.True(await connection.QuerySingleAsync<bool>("SELECT to_regclass('public.permissions_marker') IS NOT NULL"));
            Assert.Equal("003_permissions.sql", await connection.QuerySingleAsync<string>("""
                SELECT script_name FROM grate."ScriptsRun"
                """));
            Assert.Empty(await connection.QueryAsync<string>("""
                SELECT script_name FROM grate."ScriptsRunErrors"
                """));

            Assert.NotNull(error);
            Assert.Equal(PostgresErrorCodes.ForeignKeyViolation, Assert.IsType<PostgresException>(error.GetBaseException()).SqlState);
            Assert.Equal(MigrationStatus.Error, await connection.QuerySingleAsync<string>("""
                SELECT status FROM grate."Version"
                """));
        }
        finally
        {
            await context.DropDatabase(database);
        }
    }

    private void WriteScript(string folder, string file, string sql) =>
        File.WriteAllText(Path.Combine(_root.CreateSubdirectory(folder).FullName, file), sql);

    public void Dispose() => _root.Delete(recursive: true);
}
