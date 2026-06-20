using System.Data;
using Dapper;
using grate.Configuration;
using grate.Migration;
using TestCommon.Generic.Running_MigrationScripts;
using TestCommon.TestInfrastructure;

namespace TestCommon.Generic.Bootstrapping;

public abstract class When_Grate_internal_structure_is_changed(IGrateTestContext context, ITestOutputHelper testOutput)
: MigrationsScriptsBase(context, testOutput)
{

    [Fact]
    public async Task The_internal_structure_is_changed_but_the_migration_can_still_run()
    {
        var db = TestConfig.RandomDatabase();
        var parent = CreateRandomTempDirectory();

        // This will create the grate tables beforehand, without registering it

        var config = GrateConfigurationBuilder.Create(Context.DefaultConfiguration)
            .WithConnectionString(Context.ConnectionString(db))
            .WithFolders(FoldersConfiguration.Default())
            .WithSqlFilesDirectory(parent)
            .Build();

        await using (var migrator = Context.Migrator.WithConfiguration(config))
        {
            await RunMigration(migrator);
        }
        // update the internal hashes to simulate a change in internal structure
        var conn = Context.CreateDbConnection(db);
        var randomHash = Random.Shared.GetString(10);
        var scriptName = "02_create_scripts_run_table.sql";
        var updateSql = $@"UPDATE {Context.Syntax.TableWithSchema(config.SchemaName, "GrateScriptsRun")} 
                           SET text_hash = @TextHash
                           WHERE script_name = @ScriptName";
        await conn.ExecuteAsync(updateSql, new { TextHash = randomHash, ScriptName = scriptName });
        TryClose(conn);

        // run again to make sure the migration still works
        await using (var migrator = Context.Migrator.WithConfiguration(config))
        {
            await RunMigration(migrator);
        }

        var actualScriptCount = await conn.ExecuteScalarAsync<int>(
            $@"SELECT count(text_hash) FROM {Context.Syntax.TableWithSchema(config.SchemaName, "GrateScriptsRun")} 
               WHERE script_name = @ScriptName",
            new { ScriptName = scriptName });

        Assert.Equal(2, actualScriptCount);
    }
    private async Task RunMigration(IGrateMigrator migrator)
    {
        var config = migrator.Configuration;
        CreateDummySql(config.SqlFilesDirectory, config.Folders![KnownFolderKeys.Up]);
        await migrator.Migrate();
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

