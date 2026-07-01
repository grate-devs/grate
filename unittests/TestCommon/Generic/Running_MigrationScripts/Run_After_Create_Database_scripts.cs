using Dapper;
using grate.Configuration;
using TestCommon.TestInfrastructure;
using static grate.Configuration.KnownFolderKeys;

namespace TestCommon.Generic.Running_MigrationScripts;

// ReSharper disable once InconsistentNaming
public abstract class Run_After_Create_Database_scripts(IGrateTestContext context, ITestOutputHelper testOutput) 
    : MigrationsScriptsBase(context, testOutput)
{
    [Fact]
    public virtual async Task Are_run_if_the_database_is_created_from_scratch()
    {
        var db = TestConfig.RandomDatabase().ToUpper();
        
        var parent = CreateRandomTempDirectory();
        var knownFolders = Folders.Default;
        CreateDummySql(parent, knownFolders[Sprocs], "1_sprocs.sql");
        WriteSomeOtherSql(parent, knownFolders[RunAfterCreateDatabase], "1_runAfterCreateDatabase.sql");

        // Do NOT create the database manually before running the migration

        // Check that the database does not exist
        IEnumerable<string> databasesBeforeMigration = await GetDatabases();
        Assert.DoesNotContain(db, databasesBeforeMigration);
        
        // Run the migration
        var config = GrateConfigurationBuilder.Create(Context.DefaultConfiguration)
            .WithConnectionString(Context.ConnectionString(db))
            .WithFolders(knownFolders)
            .WithSqlFilesDirectory(parent)
            .Build();

        await using (var migrator = Context.Migrator.WithConfiguration(config))
        {
            await migrator.Migrate();
        }
        
        // Check that the "Run after create database" scripts have been run
        string[] scripts;
        string sql = $"SELECT script_name FROM {Context.Syntax.TableWithSchema("grate", "ScriptsRun")}";

        using (var conn = Context.External.CreateDbConnection(db))
        {
            scripts = (await conn.QueryAsync<string>(sql)).ToArray();
        }

        Assert.Equal(2, scripts.Length);

        Assert.Equal("1_runAfterCreateDatabase.sql", scripts.First());
        Assert.Equal("1_sprocs.sql", scripts.Last());
    }
    
    [Fact]
    public async Task Are_not_run_if_the_database_is_not_created_from_scratch()
    {
        var db = TestConfig.RandomDatabase().ToUpper();
        
        var parent = CreateRandomTempDirectory();
        var knownFolders = Folders.Default;
        CreateDummySql(parent, knownFolders[Sprocs], "1_sprocs.sql");
        WriteSomeOtherSql(parent, knownFolders[RunAfterCreateDatabase], "1_runAfterCreateDatabase.sql");

        // Create the database manually before running the migration
        await CreateDatabaseFromConnectionString(db, Context.UserConnectionString(db));

        // Check that the database has been created
        IEnumerable<string> databasesBeforeMigration = await GetDatabases();
        Assert.Contains(db, databasesBeforeMigration);
        
        // Run the migration
        var config = GrateConfigurationBuilder.Create(Context.DefaultConfiguration)
            .WithConnectionString(Context.ConnectionString(db))
            .WithFolders(knownFolders)
            .WithSqlFilesDirectory(parent)
            .Build();

        await using (var migrator = Context.Migrator.WithConfiguration(config))
        {
            await migrator.Migrate();
        }
        
        // Check that the "Run after create database" scripts have not been run
        string[] scripts;
        string sql = $"SELECT script_name FROM {Context.Syntax.TableWithSchema("grate", "ScriptsRun")}";

        using (var conn = Context.External.CreateDbConnection(db))
        {
            scripts = (await conn.QueryAsync<string>(sql)).ToArray();
        }

        Assert.Single(scripts);
        Assert.Equal("1_sprocs.sql", scripts.Single());
    }

    protected virtual Task<IEnumerable<string>> GetDatabases() => Context.GetDatabases(TestOutput);
    
    protected virtual Task CreateDatabaseFromConnectionString(string db, string connectionString) 
        => Context.CreateDatabaseFromConnectionString(db, connectionString, TestOutput);
}
