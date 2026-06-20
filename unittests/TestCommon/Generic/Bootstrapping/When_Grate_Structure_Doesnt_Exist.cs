using Dapper;
using FluentAssertions;
using grate.Configuration;
using grate.Infrastructure;
using grate.Migration;
using TestCommon.Generic.Running_MigrationScripts;
using TestCommon.TestInfrastructure;
using static grate.Configuration.KnownFolderKeys;

namespace TestCommon.Generic.Bootstrapping;

public abstract class When_Grate_structure_does_not_exist(IGrateTestContext context, ITestOutputHelper testOutput) 
: MigrationsScriptsBase(context, testOutput)
{
    [Fact]
    public async Task Schema_is_created()
    {
        if (!Context.SupportsSchemas)
        {
            return;
        }
        
        var db = TestConfig.RandomDatabase();
        var schemaName = Random.Shared.GetString(15);
        var parent = CreateRandomTempDirectory();
        
        var config = GrateConfigurationBuilder.Create(Context.DefaultConfiguration)
            .WithConnectionString(Context.ConnectionString(db))
            .WithSchema(schemaName)
            .WithFolders(FoldersConfiguration.Default())
            .WithSqlFilesDirectory(parent)
            .Build();

        await using (var migrator = Context.Migrator.WithConfiguration(config))
        {
            await RunMigration(migrator);
        }

        string? schema;
        string sql =
            $"SELECT s.SCHEMA_NAME FROM INFORMATION_SCHEMA.SCHEMATA s WHERE s.SCHEMA_NAME = '{schemaName}'";

        using (var conn = Context.CreateDbConnection(db))
        {
            schema = await conn.ExecuteScalarAsync<string>(sql);
        }

        schema.Should().Be(schemaName);
        
        //await Context.DropDatabase(db);
    }

    [Fact]
    public async Task ScriptsRun_Table_Is_Created()
    {
        var db = TestConfig.RandomDatabase();
        var schemaName = Random.Shared.GetString(15);
        var scriptsRunTableName = Random.Shared.GetString(15);
        var parent = CreateRandomTempDirectory();

        var config = GrateConfigurationBuilder.Create(Context.DefaultConfiguration)
            .WithConnectionString(Context.ConnectionString(db))
            .WithSchema(schemaName)
            .WithFolders(FoldersConfiguration.Default())
            .WithSqlFilesDirectory(parent)
            .Build()
            with {ScriptsRunTableName = scriptsRunTableName};

        await using var migrator = Context.Migrator.WithConfiguration(config);
        await RunMigration(migrator);

        var scriptsRunTable= await migrator.GetDbMigrator().Database.ExistingTable(schemaName, scriptsRunTableName);
        scriptsRunTable.Should().NotBeNull();
        
        // Not all databases are case-sensitive, so we can't guarantee the case of the table name
        scriptsRunTable!.ToUpper().Should().Be(scriptsRunTable.ToUpper());
        
        //await Context.DropDatabase(db);
    }
    
    [Fact]
    public async Task ScriptsRunError_Table_Is_Created()
    {
        var db = TestConfig.RandomDatabase();
        var schemaName = Random.Shared.GetString(15);
        var scriptsErrorTableName = Random.Shared.GetString(15);
        var parent = CreateRandomTempDirectory();

        var config = GrateConfigurationBuilder.Create(Context.DefaultConfiguration)
                .WithConnectionString(Context.ConnectionString(db))
                .WithSchema(schemaName)
                .WithFolders(FoldersConfiguration.Default())
                .WithSqlFilesDirectory(parent)
                .Build()
            with {ScriptsRunErrorsTableName = scriptsErrorTableName};

        await using var migrator = Context.Migrator.WithConfiguration(config);
        await RunMigration(migrator);
        
        var scriptsErrorTable = await migrator.GetDbMigrator().Database.ExistingTable(schemaName, scriptsErrorTableName);
        scriptsErrorTable.Should().NotBeNull();
        
        // Not all databases are case-sensitive, so we can't guarantee the case of the table name
        scriptsErrorTable!.ToUpper().Should().Be(scriptsErrorTableName.ToUpper());
        
        //await Context.DropDatabase(db);
    }
    
     
    [Fact]
    public async Task Version_Table_Is_Created()
    {
        var db = TestConfig.RandomDatabase();
        var schemaName = Random.Shared.GetString(15);
        var versionTableName = Random.Shared.GetString(15);
        var parent = CreateRandomTempDirectory();

        var config = GrateConfigurationBuilder.Create(Context.DefaultConfiguration)
                .WithConnectionString(Context.ConnectionString(db))
                .WithSchema(schemaName)
                .WithFolders(FoldersConfiguration.Default())
                .WithSqlFilesDirectory(parent)
                .Build()
            with {VersionTableName = versionTableName};

        await using var migrator = Context.Migrator.WithConfiguration(config);
        await RunMigration(migrator);

        var versionTable = await migrator.GetDbMigrator().Database.ExistingTable(schemaName, versionTableName);
        versionTable.Should().NotBeNull();
        
        // Not all databases are case-sensitive, so we can't guarantee the case of the table name
        versionTable!.ToUpper().Should().Be(versionTable.ToUpper());
        
        //await Context.DropDatabase(db);
    }
    
    
    private async Task RunMigration(IGrateMigrator migrator)
    {
        var config = migrator.Configuration;
        CreateDummySql(config.SqlFilesDirectory, config.Folders![Sprocs]);
        await migrator.Migrate();
    }

}
