using BigQuery.TestInfrastructure;
using Dapper;
using grate.Configuration;
using TestCommon.Generic.Running_MigrationScripts;
using TestCommon.TestInfrastructure;
using static grate.Configuration.KnownFolderKeys;

namespace BigQuery.Running_MigrationScripts;

[Collection(nameof(BigQueryGrateTestContext))]
// ReSharper disable once InconsistentNaming
public class Version_registration_failures(BigQueryGrateTestContext testContext, ITestOutputHelper testOutput)
    : MigrationsScriptsBase(testContext, testOutput)
{
    [Fact]
    public async Task A_failed_version_insert_stops_the_migration_before_its_scripts()
    {
        var db = TestConfig.RandomDatabase();
        var parent = CreateRandomTempDirectory();
        var knownFolders = Folders.Default;
        WriteSql(parent, knownFolders[Up]!.Path, "1_first.sql", "CREATE TABLE first_table (id INT64);");

        var config = GrateConfigurationBuilder.Create(Context.DefaultConfiguration)
            .WithConnectionString(Context.ConnectionString(db))
            .WithFolders(knownFolders)
            .WithSqlFilesDirectory(parent)
            .Build();

        await using (var migrator = Context.Migrator.WithConfiguration(config))
        {
            await migrator.Migrate();
        }

        // the next version registration fails, as it would without the right to read or write the version table
        using (var conn = Context.External.CreateDbConnection(db))
        {
            await conn.ExecuteAsync($"DROP TABLE `{db}`.{Context.Syntax.TableWithSchema("grate", "Version")}");
        }

        WriteSql(parent, knownFolders[Up]!.Path, "2_second.sql", "CREATE TABLE second_table (id INT64);");

        Exception exception;
        await using (var migrator = Context.Migrator.WithConfiguration(config))
        {
            exception = await Assert.ThrowsAnyAsync<Exception>(() => migrator.Migrate());
        }

        Assert.Contains("grate_Version", exception.Message);

        string[] tables;
        using (var conn = Context.External.CreateDbConnection(db))
        {
            tables = (await conn.QueryAsync<string>("SELECT table_name FROM INFORMATION_SCHEMA.TABLES")).ToArray();
        }

        Assert.Contains("first_table", tables);
        Assert.DoesNotContain("second_table", tables);
    }
}
