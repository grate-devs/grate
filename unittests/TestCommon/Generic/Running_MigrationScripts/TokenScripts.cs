using Dapper;
using grate.Configuration;
using TestCommon.TestInfrastructure;
using static grate.Configuration.KnownFolderKeys;

namespace TestCommon.Generic.Running_MigrationScripts;

public abstract class TokenScripts(IGrateTestContext context, ITestOutputHelper testOutput) 
    : MigrationsScriptsBase(context, testOutput)
{
    protected TokenScripts(): this(null!, null!)
    {
    }

    protected virtual string CreateDatabaseName => "create view grate as select '{{DatabaseName}}' as dbase";
    protected virtual string CreateViewMyCustomToken => "create view grate as select '{{MyCustomToken}}' as dbase";

    [Fact]
    public async Task Tokens_are_replaced()
    {
        var db = TestConfig.RandomDatabase().ToUpper();

        var parent = CreateRandomTempDirectory();
        var knownFolders = Folders.Default;
        var path = new DirectoryInfo(Path.Combine(parent.ToString(), knownFolders[Views]?.Path ?? throw new Exception("Config Fail")));

        WriteSql(path, "token.sql", CreateDatabaseName);

        var config = GrateConfigurationBuilder.Create(Context.DefaultConfiguration)
            .WithConnectionString(Context.ConnectionString(db))
            .WithFolders(knownFolders)
            .WithSqlFilesDirectory(parent)
            .Build();

        await using (var migrator = Context.Migrator.WithConfiguration(config))
        {
            await migrator.Migrate();
        }

        string sql = $"SELECT dbase FROM grate";
        using var conn = Context.External.CreateDbConnection(db);
        var actual = await conn.QuerySingleAsync<string>(sql);
        Assert.Equal(db, actual);
        
        //await Context.DropDatabase(db);

    }

    [Fact]
    public async Task User_tokens_are_replaced()
    {
        var db = TestConfig.RandomDatabase();

        var parent = CreateRandomTempDirectory();
        var knownFolders = Folders.Default;
        var path = new DirectoryInfo(Path.Combine(parent.ToString(), knownFolders[Views]?.Path ?? throw new Exception("Config Fail")));

        WriteSql(path, "token.sql", CreateViewMyCustomToken);
        
        var config = GrateConfigurationBuilder.Create(Context.DefaultConfiguration)
            .WithConnectionString(Context.ConnectionString(db))
            .WithUserTokens("mycustomtoken=token1")
            .WithSqlFilesDirectory(parent)
            .Build();
        
        await using (var migrator = Context.Migrator.WithConfiguration(config))
        {
            await migrator.Migrate();
        }

        string sql = $"SELECT dbase FROM grate";
        using var conn = Context.External.CreateDbConnection(db);
        var actual = await conn.QuerySingleAsync<string>(sql);
        Assert.Equal("token1", actual);
        
        //await Context.DropDatabase(db);
    }
}
