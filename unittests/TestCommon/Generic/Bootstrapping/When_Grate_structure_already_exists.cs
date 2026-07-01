using System.Data;
using System.Text.RegularExpressions;
using Dapper;
using grate.Configuration;
using grate.Infrastructure;
using grate.Migration;
using TestCommon.Generic.Running_MigrationScripts;
using TestCommon.TestInfrastructure;

namespace TestCommon.Generic.Bootstrapping;

// ReSharper disable once UnusedType.Global
public abstract class When_Grate_structure_already_exists(IGrateTestContext context, ITestOutputHelper testOutput)
    : MigrationsScriptsBase(context, testOutput)
{

    [Fact]
    public async Task The_initial_structure_is_created_as_a_baseline()
    {
        var db = TestConfig.RandomDatabase();
        var parent = CreateRandomTempDirectory();
        
        // This will create the grate tables beforehand, without registering it
           
        var config = GrateConfigurationBuilder.Create(Context.DefaultConfiguration)
            .WithConnectionString(Context.ConnectionString(db))
            .WithFolders(FoldersConfiguration.Default())
            .WithSqlFilesDirectory(parent)
            .Build();
        
        // Create database
        using (var adminConn = Context.CreateAdminDbConnection())
        {
            await adminConn.ExecuteAsync(Context.Syntax.CreateDatabase(db, null));
        }
        
        var conn = Context.CreateDbConnection(db);

        var resources = TestInfrastructure.Bootstrapping.GetBootstrapScripts(this.Context.DatabaseType, "Baseline");
        
        foreach (var resource in resources)
        {
            var resourceText = await TestInfrastructure.Bootstrapping.GetContent(this.Context.DatabaseType.Assembly, resource);
          
            resourceText = resourceText.Replace("{{ScriptsRunTable}}", config.ScriptsRunTableName);
            resourceText = resourceText.Replace("{{ScriptsRunErrorsTable}}", config.ScriptsRunErrorsTableName);
            resourceText = resourceText.Replace("{{VersionTable}}", config.VersionTableName);
            resourceText = resourceText.Replace("{{SchemaName}}", config.SchemaName);
            
            await conn.ExecuteAsync(resourceText);
        }

        conn.Close();
        
        // Check that the tables have been created
        var tableWithSchema = Context.Syntax.TableWithSchema(config.SchemaName, config.VersionTableName);
        var selectSql = $"SELECT * FROM {tableWithSchema}";
        
        conn = Context.CreateDbConnection(db);
        var reader = await conn.ExecuteReaderAsync(selectSql);
        
        var columns = GetColumns(reader).Select(column => column.ToUpper());
        TryClose(conn);
        Assert.NotEmpty(columns);
        
        // Run the migration
        await using (var migrator = Context.Migrator.WithConfiguration(config))
        {
            await RunMigration(migrator);
        }
        
        // Check that the scripts have been registered as a baseline:
        
        // We should have at least 6 rows in the ScriptsRun table, as there are 3 or 4 scripts in the baseline,
        // depending on whether the database supports schemas or not
        var grateInternalScriptsRunTable = Context.Syntax.TableWithSchema(config.SchemaName, "GrateScriptsRun");
        selectSql = $"SELECT COUNT(*) FROM {grateInternalScriptsRunTable}";
        conn = Context.CreateDbConnection(db);
        var count = await conn.QueryFirstOrDefaultAsync<int>(selectSql);
        Assert.True(count >= 6);
        
        TryClose(conn);
        
        //await Context.DropDatabase(db);
    }



    private async Task RunMigration(IGrateMigrator migrator)
    {
        var config = migrator.Configuration;
        CreateDummySql(config.SqlFilesDirectory, config.Folders![KnownFolderKeys.Up]);
        await migrator.Migrate();
    }

    private static List<string> GetColumns(IDataReader reader)
    {
        var columns = Enumerable.Range(0, reader.FieldCount)
            .Select(reader.GetName)
            .ToList();
        return columns;
    }
    
    private static void TryClose(IDbConnection conn)
    {
        try
        {
            if (conn.State == ConnectionState.Open)
            {
                conn.Close();
            }
        }
        catch (Exception)
        {
            // ignored
        }
    }
    
}

