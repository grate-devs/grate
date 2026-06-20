using Dapper;
using FluentAssertions;
using FluentAssertions.Execution;
using grate.Configuration;
using grate.Migration;
using TestCommon.TestInfrastructure;
using static grate.Configuration.KnownFolderKeys;

namespace TestCommon.Generic.Running_MigrationScripts;

//[TestFixture]
// ReSharper disable once InconsistentNaming
public abstract class Anytime_scripts(IGrateTestContext context, ITestOutputHelper testOutput) 
    : MigrationsScriptsBase(context, testOutput)
{
    protected Anytime_scripts(): this(null!, null!)
    {
    }
  
    
    [Fact]
    public async Task Are_not_run_more_than_once_when_unchanged()
    {
        var db = TestConfig.RandomDatabase();

        var parent = CreateRandomTempDirectory();
        var knownFolders = Folders.Default;
        CreateDummySql(parent, knownFolders[Sprocs]);
        
        var config = GrateConfigurationBuilder.Create(Context.DefaultConfiguration)
            .WithConnectionString(Context.ConnectionString(db))
            .WithFolders(knownFolders)
            .WithSqlFilesDirectory(parent)
            .Build();
        
        await using (var migrator = Context.Migrator.WithConfiguration(config))
        {
            await migrator.Migrate();
        }
        await using (var migrator = Context.Migrator.WithConfiguration(config))
        {
            await migrator.Migrate();
        }

        string[] scripts;
        string sql = $"SELECT script_name FROM {Context.Syntax.TableWithSchema("grate", "ScriptsRun")}";

        using (var conn = Context.External.CreateDbConnection(db))
        {
            scripts = (await conn.QueryAsync<string>(sql)).ToArray();
        }

        scripts.Should().HaveCount(1);
        
        //await Context.DropDatabase(db);
    }

    [Fact]
    public async Task Are_run_again_if_changed_between_runs()
    {
        var db = TestConfig.RandomDatabase();

        var parent = CreateRandomTempDirectory();
        var knownFolders = Folders.Default;
        CreateDummySql(parent, knownFolders[Sprocs]);

        var config = GrateConfigurationBuilder.Create(Context.DefaultConfiguration)
            .WithConnectionString(Context.ConnectionString(db))
            .WithFolders(knownFolders)
            .WithSqlFilesDirectory(parent)
            .Build();
        
        await using (var migrator = Context.Migrator.WithConfiguration(config))
        {
            await migrator.Migrate();
        }

        WriteSomeOtherSql(parent, knownFolders[Sprocs]);

        await using (var migrator = Context.Migrator.WithConfiguration(config))
        {
            await migrator.Migrate();
        }

        string[] scripts;
        string sql = $"SELECT text_of_script FROM {Context.Syntax.TableWithSchema("grate", "ScriptsRun")} ORDER BY id";

        using (var conn = Context.External.CreateDbConnection(db))
        {
            scripts = (await conn.QueryAsync<string>(sql)).ToArray();
        }

        scripts.Should().HaveCount(2);

        using (new AssertionScope())
        {
            scripts.First().Should().Be(Context.Sql.SelectVersion);
            scripts.Last().Should().Be(Context.Syntax.CurrentDatabase);
        }
        
        //await Context.DropDatabase(db);
    }

    [Fact]
    public async Task Do_not_have_text_logged_if_flag_set()
    {
        var db = TestConfig.RandomDatabase();

        IGrateMigrator? migrator;

        var parent = CreateRandomTempDirectory();
        var knownFolders = Folders.Default;
        CreateDummySql(parent, knownFolders[Sprocs]);
        
        var config = GrateConfigurationBuilder.Create(Context.DefaultConfiguration)
            .WithConnectionString(Context.ConnectionString(db))
            .WithSqlFilesDirectory(parent)
            .DoNotStoreScriptsRunText() // important
            .Build();

        await using (migrator = Context.Migrator.WithConfiguration(config))
        {
            await migrator.Migrate();
        }

        string[] scripts;
        string sql = $"SELECT text_of_script FROM {Context.Syntax.TableWithSchema("grate", "ScriptsRun")}";

        using (var conn = Context.External.CreateDbConnection(db))
        {
            scripts = (await conn.QueryAsync<string>(sql)).ToArray();
        }

        scripts.Should().HaveCount(1);
        scripts.Single().Should().Be(null);
        
        //await Context.DropDatabase(db);
    }

    [Fact]
    public async Task Do_have_text_logged_by_default()
    {
        var db = TestConfig.RandomDatabase();

        IGrateMigrator? migrator;

        var parent = CreateRandomTempDirectory();
        var knownFolders = Folders.Default;
        CreateDummySql(parent, knownFolders[Sprocs]);
        
        var config = GrateConfigurationBuilder.Create(Context.DefaultConfiguration)
            .WithConnectionString(Context.ConnectionString(db))
            .WithSqlFilesDirectory(parent)
            .Build();

        await using (migrator = Context.External.Migrator.WithConfiguration(config))
        {
            await migrator.Migrate();
        }

        string[] scripts;
        string sql = $"SELECT text_of_script FROM {Context.Syntax.TableWithSchema("grate", "ScriptsRun")}";

        using (var conn = Context.External.CreateDbConnection(db))
        {
            scripts = (await conn.QueryAsync<string>(sql)).ToArray();
        }

        scripts.Should().HaveCount(1);
        scripts.Single().Should().Be(Context.Sql.SelectVersion);
        
        //await Context.DropDatabase(db);
    }

    [Fact]
    public async Task Are_run_more_than_once_when_unchanged_but_flag_set()
    {
        var db = TestConfig.RandomDatabase();

        IGrateMigrator? migrator;

        var parent = CreateRandomTempDirectory();
        var knownFolders = Folders.Default;
        CreateDummySql(parent, knownFolders[Sprocs]);
        
        var config = GrateConfigurationBuilder.Create(Context.DefaultConfiguration)
            .WithConnectionString(Context.ConnectionString(db))
            .WithSqlFilesDirectory(parent)
            .RunAllAnyTimeScripts() // important
            .Build();

        await using (migrator = Context.Migrator.WithConfiguration(config))
        {
            await migrator.Migrate();
        }
        await using (migrator = Context.Migrator.WithConfiguration(config))
        {
            await migrator.Migrate();
        }

        string[] scripts;
        string sql = $"SELECT script_name FROM {Context.Syntax.TableWithSchema("grate", "ScriptsRun")}";

        using (var conn = Context.External.CreateDbConnection(db))
        {
            scripts = (await conn.QueryAsync<string>(sql)).ToArray();
        }

        scripts.Should().HaveCount(2);
        
        //await Context.DropDatabase(db);
    }
}
