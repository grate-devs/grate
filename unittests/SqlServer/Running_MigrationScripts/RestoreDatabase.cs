using Dapper;
using grate.Configuration;
using SqlServer.TestInfrastructure;
using TestCommon.TestInfrastructure;

namespace SqlServer.Running_MigrationScripts;


[Collection(nameof(SqlServerGrateTestContext))]
// ReSharper disable once InconsistentNaming
public class RestoreDatabase(SqlServerGrateTestContext testContext, ITestOutputHelper testOutput)
    : SqlServerScriptsBase(testContext, testOutput)
{
    
    private static readonly string BackedUpDb = TestConfig.RandomDatabase();
    private static readonly string BackupPath = $"/var/opt/mssql/backup/{BackedUpDb}.bak";


    private async Task RunBeforeTest()
    {
        using var conn = Context.CreateDbConnection("master");
        await conn.ExecuteAsync($"use [master] CREATE DATABASE [{BackedUpDb}]");
        await conn.ExecuteAsync($"use [{BackedUpDb}] CREATE TABLE dbo.Table_1 (column1 int NULL)");
        await conn.ExecuteAsync($"BACKUP DATABASE [{BackedUpDb}] TO  DISK = '{BackupPath}'");
        await conn.ExecuteAsync($"use [master] DROP DATABASE [{BackedUpDb}]");
    }

    [Fact]
    public async Task Ensure_database_gets_restored()
    {
        await RunBeforeTest();

        var db = TestConfig.RandomDatabase();

        var parent = CreateRandomTempDirectory();
        var knownFolders = Folders.Default;
        CreateDummySql(parent, knownFolders[KnownFolderKeys.Sprocs]);

        var restoreConfig = GrateConfigurationBuilder.Create(Context.DefaultConfiguration)
            .WithConnectionString(Context.ConnectionString(db))
            .WithSqlFilesDirectory(parent)
            .RestoreFrom(BackupPath)
            .Build();

        await using (var migrator = Context.Migrator.WithConfiguration(restoreConfig))
        {
            await migrator.Migrate();
        }

        int[] results;
        string sql = $"select count(1) from sys.tables where [name]='Table_1'";

        using (var conn = Context.CreateDbConnection(db))
        {
            results = (await conn.QueryAsync<int>(sql)).ToArray();
        }

        Assert.Equal(1, results.First());
        
        //await Context.DropDatabase(db);
    }
}
