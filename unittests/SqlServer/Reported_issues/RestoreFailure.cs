using Dapper;
using grate.Configuration;
using Microsoft.Data.SqlClient;
using SqlServer.TestInfrastructure;
using TestCommon.TestInfrastructure;

namespace SqlServer.Reported_issues;

[Collection(nameof(SqlServerGrateTestContext))]
public class RestoreFailure(SqlServerGrateTestContext testContext)
{
    [Fact]
    public async Task Unknown_logical_file_leaves_existing_database_in_multi_user_mode()
    {
        IGrateTestContext context = testContext;
        var databasePrefix = TestConfig.RandomDatabase();
        var database = $"{databasePrefix}] restore";
        var quotedDatabase = $"[{databasePrefix}]] restore]";
        var backupPath = $"/var/opt/mssql/backup/{databasePrefix}.bak";
        const string unknownLogicalName = "Unknown logical file";
        var destinationPath = $"/var/opt/mssql/data/{databasePrefix}-relocated.mdf";

        using var admin = context.CreateAdminDbConnection();
        var root = Directory.CreateTempSubdirectory("grate-restore-failure-");
        try
        {
            await admin.ExecuteAsync($"CREATE DATABASE {quotedDatabase};");
            await admin.ExecuteAsync($"""
                CREATE TABLE {quotedDatabase}.dbo.ExistingData (id int NOT NULL);
                BACKUP DATABASE {quotedDatabase} TO DISK = @backupPath;
                INSERT INTO {quotedDatabase}.dbo.ExistingData VALUES (593);
                """, new { backupPath });

            var config = GrateConfigurationBuilder.Create(context.DefaultConfiguration)
                .WithConnectionString(context.ConnectionString(database))
                .WithSqlFilesDirectory(root)
                .WithOutputFolder(root.CreateSubdirectory("output"))
                .RestoreFrom(backupPath)
                .WithRestoreMoves(new RestoreFileMove(unknownLogicalName, destinationPath))
                .Build();
            await using var migrator = context.Migrator.WithConfiguration(config);

            var error = await Assert.ThrowsAsync<SqlException>(migrator.Migrate);

            Assert.Contains(unknownLogicalName, error.Message);
            Assert.Equal("MULTI_USER", await admin.QuerySingleAsync<string>(
                "SELECT user_access_desc FROM sys.databases WHERE name = @database;", new { database }));
            using var target = context.CreateDbConnection(database);
            Assert.Equal(593, await target.QuerySingleAsync<int>("SELECT id FROM dbo.ExistingData;"));
        }
        finally
        {
            try
            {
                await admin.ExecuteAsync($"DROP DATABASE IF EXISTS {quotedDatabase};");
            }
            finally
            {
                root.Delete(recursive: true);
            }
        }
    }
}
