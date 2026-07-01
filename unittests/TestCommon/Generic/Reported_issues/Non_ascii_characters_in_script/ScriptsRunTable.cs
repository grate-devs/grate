using Dapper;
using grate.Configuration;
using TestCommon.Generic.Running_MigrationScripts;
using TestCommon.TestInfrastructure;

namespace TestCommon.Generic.Reported_issues.Non_ascii_characters_in_script;

public abstract class ScriptsRunTable(IGrateTestContext context, ITestOutputHelper testOutput) 
    : MigrationsScriptsBase(context, testOutput)
{
    protected ScriptsRunTable() : this(null!, null!)
    {
    }
    

    [Theory]
    [InlineData("Blåbærkake")]
    [InlineData("لا أحب الطقس الممطر")]
    [InlineData("Я коричневая черепаха")]
    [InlineData("✨")]
    [InlineData("🎉")]
    [InlineData("👍")]
    public async Task Text_of_script(string characters)
    {
        var sql = $"""
                {Context.Sql.LineComment} This is a comment: {characters}
                {Context.Sql.SelectVersion}
                """;
        
        var db = TestConfig.RandomDatabase();

            var parent = CreateRandomTempDirectory();
            var knownFolders = Folders.Default;
            var filename = "1_script_with_utf_characters.sql";
            WriteSql(Wrap(parent, knownFolders[KnownFolderKeys.Up]!.Path), filename, sql);
        
            var config = GrateConfigurationBuilder.Create(Context.DefaultConfiguration)
                .WithConnectionString(Context.ConnectionString(db))
                .WithFolders(knownFolders)
                .WithSqlFilesDirectory(parent)
                .Build();
        
            await using (var migrator = Context.Migrator.WithConfiguration(config))
            {
                await migrator.Migrate();
            }

            string[] scripts;
            string selectSql = $"SELECT text_of_script FROM {Context.Syntax.TableWithSchema("grate", "ScriptsRun")}";

            using (var conn = Context.CreateDbConnection(db))
            {
                scripts = (await conn.QueryAsync<string>(selectSql)).ToArray();
            }

            Assert.Single(scripts);
            Assert.Equal(sql, scripts.First());
            Assert.Contains(characters, scripts.First());
        
        //await Context.DropDatabase(db);
    }
    
    [Theory]
    [InlineData("det_første.sql")]
    [InlineData("الأول.sql")]
    [InlineData("первый_script.sql")]
    [InlineData("✨.sql")]
    [InlineData("🎉.sql")]
    [InlineData("👍.sql")]
    public async Task Script_name(string scriptName)
    {
        var sql = $"""
                   {Context.Sql.LineComment} This is a comment: комментарий
                   {Context.Sql.SelectVersion}
                   """;
        
        var db = TestConfig.RandomDatabase();

        var parent = CreateRandomTempDirectory();
        var knownFolders = Folders.Default;
        var filename = scriptName;
        WriteSql(Wrap(parent, knownFolders[KnownFolderKeys.Up]!.Path), filename, sql);
        
        var config = GrateConfigurationBuilder.Create(Context.DefaultConfiguration)
            .WithConnectionString(Context.ConnectionString(db))
            .WithFolders(knownFolders)
            .WithSqlFilesDirectory(parent)
            .Build();
        
        await using (var migrator = Context.Migrator.WithConfiguration(config))
        {
            await migrator.Migrate();
        }

        string[] scripts;
        string selectSql = $"SELECT script_name FROM {Context.Syntax.TableWithSchema("grate", "ScriptsRun")}";

        using (var conn = Context.CreateDbConnection(db))
        {
            scripts = (await conn.QueryAsync<string>(selectSql)).ToArray();
        }

        Assert.Single(scripts);
        Assert.Equal(scriptName, scripts.First());
        
        //await Context.DropDatabase(db);
    }
}
