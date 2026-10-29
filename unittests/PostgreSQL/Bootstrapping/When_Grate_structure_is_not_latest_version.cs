using Dapper;
using grate.Configuration;
using PostgreSQL.TestInfrastructure;
using TestCommon.TestInfrastructure;

namespace PostgreSQL.Bootstrapping;

[Collection(nameof(PostgreSqlGrateTestContext))]
// ReSharper disable once InconsistentNaming
// ReSharper disable once UnusedType.Global
public class When_Grate_structure_is_not_latest_version(PostgreSqlGrateTestContext context, ITestOutputHelper testOutput) 
    : TestCommon.Generic.Bootstrapping.When_Grate_structure_is_not_latest_version(context, testOutput)
{
    [Fact]
    public async Task Pending_internal_version_table_casing_upgrade_runs_before_application_scripts()
    {
        var database = TestConfig.RandomDatabase();
        var scripts = CreateRandomTempDirectory();
        var config = Context.DefaultConfiguration with
        {
            ConnectionString = Context.ConnectionString(database),
            SqlFilesDirectory = scripts,
            Version = "v1"
        };
        WriteSql(scripts, "up", "001.sql", "CREATE TABLE before_casing_upgrade(id INTEGER);");
        await using (var migrator = Context.Migrator.WithConfiguration(config))
        {
            await migrator.Migrate();
        }

        using var connection = Context.CreateDbConnection(database);
        await connection.ExecuteAsync("""
            ALTER TABLE grate."GrateVersion" RENAME TO grateversion;
            DELETE FROM grate."GrateScriptsRun"
            WHERE script_name LIKE '%00_02_fix_version_table_casing.sql';
            """);
        WriteSql(scripts, "up", "002.sql", "CREATE TABLE after_casing_upgrade(id INTEGER);");

        await using (var migrator = Context.Migrator.WithConfiguration(config with { Version = "v2" }))
        {
            await migrator.Migrate();
        }

        Assert.Equal("GrateVersion", await connection.ExecuteScalarAsync<string>("""
            SELECT table_name FROM information_schema.tables
            WHERE table_schema = 'grate' AND lower(table_name) = 'grateversion'
            """));
        Assert.Equal(1, await connection.ExecuteScalarAsync<int>("""
            SELECT COUNT(*) FROM information_schema.tables WHERE table_name = 'after_casing_upgrade'
            """));
        Assert.Equal(("v2", MigrationStatus.Finished), await connection.QuerySingleAsync<(string, string)>("""
            SELECT v.version, v.status FROM grate."ScriptsRun" s
            JOIN grate."Version" v ON s.version_id = v.id WHERE s.script_name = '002.sql'
            """));
    }
}

