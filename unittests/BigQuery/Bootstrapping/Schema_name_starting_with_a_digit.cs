using BigQuery.TestInfrastructure;
using Dapper;
using grate.Configuration;
using TestCommon.Generic.Running_MigrationScripts;
using TestCommon.TestInfrastructure;
using static grate.Configuration.KnownFolderKeys;

namespace BigQuery.Bootstrapping;

[Collection(nameof(BigQueryGrateTestContext))]
// ReSharper disable once InconsistentNaming
public class Schema_name_starting_with_a_digit(BigQueryGrateTestContext testContext, ITestOutputHelper testOutput)
    : MigrationsScriptsBase(testContext, testOutput)
{
    [Fact]
    public async Task Grates_tables_are_created_and_used()
    {
        // GoogleSQL takes a name that starts with a digit only in backticks
        var db = TestConfig.RandomDatabase();
        var parent = CreateRandomTempDirectory();
        var knownFolders = Folders.Default;
        WriteSql(parent, knownFolders[Up]!.Path, "1_first.sql", "CREATE TABLE first_table (id INT64);");

        var config = GrateConfigurationBuilder.Create(Context.DefaultConfiguration)
            .WithConnectionString(Context.ConnectionString(db))
            .WithFolders(knownFolders)
            .WithSqlFilesDirectory(parent)
            .WithSchema("123")
            .Build();

        await using (var migrator = Context.Migrator.WithConfiguration(config))
        {
            await migrator.Migrate();
        }

        string[] tables;
        string[] scripts;
        using (var conn = Context.External.CreateDbConnection(db))
        {
            tables = (await conn.QueryAsync<string>("SELECT table_name FROM INFORMATION_SCHEMA.TABLES")).ToArray();
            scripts = (await conn.QueryAsync<string>($"SELECT script_name FROM `{db}`.`123_ScriptsRun`")).ToArray();
        }

        Assert.Contains("1_first.sql", scripts);
        Assert.Contains("123_GrateScriptsRun", tables);
        Assert.Contains("123_ScriptsRun", tables);
        Assert.Contains("123_ScriptsRunErrors", tables);
        Assert.Contains("123_Version", tables);
        Assert.Contains("first_table", tables);
    }
}
