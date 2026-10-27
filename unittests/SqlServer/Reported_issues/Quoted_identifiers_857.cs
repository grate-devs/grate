using Dapper;
using grate.Configuration;
using SqlServer.TestInfrastructure;
using TestCommon.Generic.Running_MigrationScripts;
using TestCommon.TestInfrastructure;

namespace SqlServer.Reported_issues;

// ReSharper disable once InconsistentNaming
[Collection(nameof(SqlServerGrateTestContext))]
public class Quoted_identifiers_857(SqlServerGrateTestContext context, ITestOutputHelper testOutput)
    : MigrationsScriptsBase(context, testOutput)
{
    [Fact]
    public async Task Migrates_columns_named_go_and_escaped_quoted_identifiers()
    {
        var db = TestConfig.RandomDatabase();
        var parent = CreateRandomTempDirectory();
        var folders = Folders.Default;
        var path = Wrap(parent, folders[KnownFolderKeys.Up]!.Path);
        WriteSql(path, "quoted_identifiers.sql", """
            SET QUOTED_IDENTIFIER ON;
            CREATE TABLE settings ([go] int, [escaped]]go] int, "escaped""go" int);
            INSERT INTO settings VALUES (17, 23, 29);
            GO -- separate the table definition from its use
            CREATE TABLE selected_values (value int);
            INSERT INTO selected_values SELECT [go] FROM [settings];
            INSERT INTO selected_values SELECT "go" FROM settings;
            INSERT INTO selected_values SELECT [escaped]]go] FROM settings;
            INSERT INTO selected_values SELECT "escaped""go" FROM settings;
            GO
            """);

        var config = GrateConfigurationBuilder.Create(Context.DefaultConfiguration)
            .WithConnectionString(Context.ConnectionString(db))
            .WithFolders(folders)
            .WithSqlFilesDirectory(parent)
            .Build();

        await using (var migrator = Context.Migrator.WithConfiguration(config))
        {
            await migrator.Migrate();
        }

        using var connection = Context.External.CreateDbConnection(db);
        var values = await connection.QueryAsync<int>("SELECT value FROM selected_values ORDER BY value");
        Assert.Equal([17, 17, 23, 29], values);
    }
}
