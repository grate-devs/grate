using Dapper;
using grate.Configuration;
using Sqlite.TestInfrastructure;
using TestCommon.TestInfrastructure;

namespace Sqlite.Running_MigrationScripts;

[Collection(nameof(SqliteTestDatabase))]
// ReSharper disable once InconsistentNaming
// ReSharper disable once UnusedType.Global
public class One_time_scripts(SqliteGrateTestContext testContext, ITestOutputHelper testOutput)
    : TestCommon.Generic.Running_MigrationScripts.One_time_scripts(testContext, testOutput)
{
    [Fact]
    public async Task Ignored_change_retains_its_version_without_executing_sql_or_duplicating_history_on_rerun()
    {
        var db = TestConfig.RandomDatabase();
        var parent = CreateRandomTempDirectory();
        var path = parent.CreateSubdirectory("up");
        const string originalSql = "CREATE TABLE sample(id INTEGER);";
        const string changedSql = "CREATE TABLE sample(id INTEGER, name TEXT);";
        WriteSql(path, "001.sql", originalSql);

        var config = GrateConfigurationBuilder.Create(Context.DefaultConfiguration)
            .WithConnectionString(Context.ConnectionString(db))
            .WithSqlFilesDirectory(parent)
            .WithVersion("v1")
            .WarnAndIgnoreOnOneTimeScriptChanges()
            .Build();

        await using (var migrator = Context.Migrator.WithConfiguration(config))
        {
            await migrator.Migrate();
        }

        WriteSql(path, "001.sql", changedSql);
        await using (var migrator = Context.Migrator.WithConfiguration(config with { Version = "v2" }))
        {
            await migrator.Migrate();
        }

        using var conn = Context.External.CreateDbConnection(db);
        Assert.Equal(new[] { "id" }, await conn.QueryAsync<string>("SELECT name FROM pragma_table_info('sample')"));
        var history = (await conn.QueryAsync<(long Id, long VersionId, string Sql, string Hash)>(
            "SELECT id, version_id, text_of_script, text_hash FROM grate_ScriptsRun ORDER BY id")).ToArray();
        Assert.Equal(2, history.Length);
        Assert.Equal(changedSql, history[1].Sql);
        Assert.NotEqual(history[0].Hash, history[1].Hash);
        var versions = (await conn.QueryAsync<(long Id, string Version, string Status)>(
            "SELECT id, version, status FROM grate_Version ORDER BY id")).ToArray();
        Assert.Equal(new[] { "v1", "v2" }, versions.Select(version => version.Version));
        Assert.Equal(versions[1].Id, history[1].VersionId);
        Assert.All(versions, version => Assert.Equal("Finished", version.Status));
        Assert.Equal(0, await conn.ExecuteScalarAsync<int>(
            "SELECT COUNT(*) FROM grate_ScriptsRun s LEFT JOIN grate_Version v ON v.id = s.version_id WHERE v.id IS NULL"));

        await using (var migrator = Context.Migrator.WithConfiguration(config with { Version = "v3" }))
        {
            await migrator.Migrate();
        }

        Assert.Equal(history, (await conn.QueryAsync<(long, long, string, string)>(
            "SELECT id, version_id, text_of_script, text_hash FROM grate_ScriptsRun ORDER BY id")).ToArray());
        Assert.Equal(versions, (await conn.QueryAsync<(long, string, string)>(
            "SELECT id, version, status FROM grate_Version ORDER BY id")).ToArray());
        Assert.Equal(new[] { "id" }, await conn.QueryAsync<string>("SELECT name FROM pragma_table_info('sample')"));
    }
}
