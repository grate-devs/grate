using grate.Configuration;
using SqlServer.TestInfrastructure;
using TestCommon.Generic.Running_MigrationScripts;
using TestCommon.TestInfrastructure;

namespace SqlServer.Reported_issues;

// ReSharper disable once InconsistentNaming
[Collection(nameof(SqlServerGrateTestContext))]
public class Quoted_Identifier_440(SqlServerGrateTestContext context, ITestOutputHelper testOutput) : MigrationsScriptsBase(context, testOutput)
{
    const string sql = """
                       SET QUOTED_IDENTIFIER OFF
                       GO
                       CREATE PROCEDURE [do_something_or_something_else]
                           @Blip            nvarchar(128),
                           @Blop            nvarchar(128)
                       AS
                       BEGIN
                           SELECT @@VERSION;
                       END
                       GO
                       """;

    [Fact]
    public async Task Setting_QUOTED_IDENTIFIER_OFF_in_a_script_does_not_mess_up_migration()
    {
        var db = TestConfig.RandomDatabase();

        var parent = CreateRandomTempDirectory();
        var knownFolders = FoldersConfiguration.Default();

        var path = new DirectoryInfo(Path.Combine(parent.ToString(), knownFolders[KnownFolderKeys.Sprocs]!.Path));

        WriteSql(path, "some_sproc.sql", sql);

        var config = GrateConfigurationBuilder.Create(Context.DefaultConfiguration)
            .WithConnectionString(Context.ConnectionString(db))
            .WithFolders(knownFolders)
            .WithSqlFilesDirectory(parent)
            .Build();

        await using (var migrator = Context.Migrator.WithConfiguration(config))
        {
            await migrator.Migrate();
        }

        //await Context.DropDatabase(db);
    }
}
