using Dapper;
using FluentAssertions;
using grate.Configuration;
using TestCommon.TestInfrastructure;
using static grate.Configuration.KnownFolderKeys;

namespace TestCommon.Generic.Running_MigrationScripts;

public abstract class DropDatabase(IGrateTestContext context, ITestOutputHelper testOutput) 
    : MigrationsScriptsBase(context, testOutput)
{
    protected DropDatabase(): this(null!, null!)
    {
    }
    
    [Fact]
    public async Task Ensure_database_gets_dropped()
    {
        var db = TestConfig.RandomDatabase();

        var parent = CreateRandomTempDirectory();
        var knownFolders = Folders.Default;
        CreateDummySql(parent, knownFolders[Sprocs]);
        
        var dropConfig = GrateConfigurationBuilder.Create(Context.DefaultConfiguration)
            .WithConnectionString(Context.ConnectionString(db))
            .WithSqlFilesDirectory(parent)
            .DropDatabase()  // This is important!
            .Build();
        
        await using (var migrator = Context.Migrator.WithConfiguration(dropConfig))
        {
            await migrator.Migrate();
        }

        WriteSomeOtherSql(parent, knownFolders[Sprocs]);

        await using (var migrator = Context.Migrator.WithConfiguration(dropConfig))
        {
            // This second migration should drop and recreate, so only one script run afterwards
            await migrator.Migrate();
        }

        string[] scripts;
        string sql = $"SELECT text_of_script FROM {Context.Syntax.TableWithSchema("grate", "ScriptsRun")}";

        using (var conn = Context.External.CreateDbConnection(db))
        {
            scripts = (await conn.QueryAsync<string>(sql)).ToArray();
        }

        scripts.Should().HaveCount(1); // only one script because the database was dropped after the first migration...
    }
}
