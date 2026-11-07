using Dapper;
using grate.Configuration;
using SqlServer.TestInfrastructure;
using TestCommon.TestInfrastructure;

namespace SqlServer.Running_MigrationScripts;

[Collection(nameof(SqlServerGrateTestContext))]
public class RestoreDatabase(SqlServerGrateTestContext testContext, ITestOutputHelper testOutput)
    : SqlServerScriptsBase(testContext, testOutput)
{
    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public async Task Restores_both_files_and_migrates(bool moveFiles)
    {
        var source = TestConfig.RandomDatabase();
        var targetPrefix = TestConfig.RandomDatabase();
        var target = moveFiles ? $"{targetPrefix}] mapped" : targetPrefix;
        var quotedTarget = moveFiles ? $"[{targetPrefix}]] mapped]" : $"[{targetPrefix}]";
        var backupPath = $"/var/opt/mssql/backup/{source} owner's copy.bak";
        var originalData = $"/var/opt/mssql/data/{source}.mdf";
        var originalLog = $"/var/opt/mssql/data/{source}_log.ldf";
        var dataPath = $"/var/opt/mssql/data/{target} owner's moved=data.mdf";
        var logPath = $"/var/opt/mssql/data/{target} owner's moved=log.ldf";
        const string scriptName = "001_copy_restored_data.sql";

        var root = Directory.CreateTempSubdirectory("grate-restore-");
        using var admin = Context.CreateAdminDbConnection();
        try
        {
            await admin.ExecuteAsync($"""
                CREATE DATABASE [{source}]
                ON PRIMARY (NAME = N'Owner''s data', FILENAME = N'{originalData}')
                LOG ON (NAME = N'Owner''s log', FILENAME = N'{originalLog}');
                """);
            await admin.ExecuteAsync($"""
                CREATE TABLE [{source}].dbo.BackupData (id int NOT NULL);
                INSERT INTO [{source}].dbo.BackupData VALUES (593);
                BACKUP DATABASE [{source}] TO DISK = @backupPath;
                """, new { backupPath });

            // With MOVE, keep the original files in use so either missing mapping fails.
            if (moveFiles)
            {
                await admin.ExecuteAsync($"CREATE DATABASE {quotedTarget};");
            }
            else
            {
                await Context.DropDatabase(source);
            }

            var scripts = root.CreateSubdirectory("scripts");
            WriteSql(scripts, "up", scriptName, "SELECT id INTO dbo.MigratedData FROM dbo.BackupData;");
            var builder = GrateConfigurationBuilder.Create(Context.DefaultConfiguration)
                .WithConnectionString(Context.ConnectionString(target))
                .WithSqlFilesDirectory(scripts)
                .WithOutputFolder(root.CreateSubdirectory("output"))
                .RestoreFrom(backupPath);
            if (moveFiles)
            {
                builder.WithRestoreMoves(new("Owner's data", dataPath), new("Owner's log", logPath));
            }

            await using (var migrator = Context.Migrator.WithConfiguration(builder.Build()))
            {
                await migrator.Migrate();
            }

            using var restored = Context.CreateDbConnection(target);
            var paths = await restored.QueryAsync<string>(
                "SELECT physical_name FROM sys.database_files WHERE type IN (0, 1) ORDER BY type;");
            Assert.Equal(moveFiles ? [dataPath, logPath] : new[] { originalData, originalLog }, paths);
            Assert.Equal(593, await restored.QuerySingleAsync<int>("SELECT id FROM dbo.MigratedData;"));
            Assert.Equal(1, await restored.QuerySingleAsync<int>(
                "SELECT COUNT(*) FROM grate.ScriptsRun WHERE script_name = @scriptName;", new { scriptName }));
        }
        finally
        {
            try
            {
                await admin.ExecuteAsync($"DROP DATABASE IF EXISTS {quotedTarget};");
                await Context.DropDatabase(source);
            }
            finally
            {
                root.Delete(recursive: true);
            }
        }
    }
}
