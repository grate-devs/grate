using Dapper;
using grate.Configuration;
using Microsoft.Data.SqlClient;
using SqlServer.TestInfrastructure;
using TestCommon.Generic.Running_MigrationScripts;
using TestCommon.TestInfrastructure;

namespace SqlServer.Running_MigrationScripts;

[Collection(nameof(SqlServerGrateTestContext))]
public class Database_readiness(SqlServerGrateTestContext context, ITestOutputHelper testOutput)
    : MigrationsScriptsBase(context, testOutput)
{
    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public async Task New_database_runs_creation_and_up_scripts_with_connection_pooling(bool customCreation)
    {
        var database = TestConfig.RandomDatabase();
        var parent = CreateRandomTempDirectory();
        var builder = new SqlConnectionStringBuilder(Context.ConnectionString(database));
        // The fixture disables pooling. Use SqlClient's default pooling behavior,
        // including its cached login failure when DatabaseExists probes a missing database.
        builder.Remove("Pooling");
        builder.PoolBlockingPeriod = PoolBlockingPeriod.AlwaysBlock;
        var config = Context.DefaultConfiguration with
        {
            ConnectionString = builder.ConnectionString,
            SqlFilesDirectory = parent
        };

        try
        {
            if (customCreation)
            {
                WriteSql(Wrap(parent, "createDatabase"), "create.sql", "CREATE DATABASE [{{DatabaseName}}];");
            }

            WriteSql(Wrap(parent, "runAfterCreateDatabase"), "after_create.sql", """
                CREATE TABLE creation_marker (value int NOT NULL);
                INSERT INTO creation_marker VALUES (17);
                """);
            WriteSql(Wrap(parent, "up"), "up.sql", "INSERT INTO creation_marker VALUES (23);");

            await using (var migrator = Context.Migrator.WithConfiguration(config))
            {
                await migrator.Migrate();
            }

            using var connection = Context.External.CreateDbConnection(database);
            Assert.Equal([17, 23], await connection.QueryAsync<int>("SELECT value FROM creation_marker ORDER BY value"));
            Assert.Equal(["after_create.sql", "up.sql"], await connection.QueryAsync<string>(
                "SELECT script_name FROM grate.ScriptsRun ORDER BY id"));
            Assert.Equal(0, await connection.ExecuteScalarAsync<int>("SELECT COUNT(*) FROM grate.ScriptsRunErrors"));

            // A rerun must not rerun the creation-only script or the one-time up script.
            await using (var migrator = Context.Migrator.WithConfiguration(config))
            {
                await migrator.Migrate();
            }

            Assert.Equal([17, 23], await connection.QueryAsync<int>("SELECT value FROM creation_marker ORDER BY value"));
            Assert.Equal(2, await connection.ExecuteScalarAsync<int>("SELECT COUNT(*) FROM grate.ScriptsRun"));
        }
        finally
        {
            using var poolConnection = new SqlConnection(config.ConnectionString);
            SqlConnection.ClearPool(poolConnection);
            using var admin = Context.External.CreateAdminDbConnection();
            await admin.ExecuteAsync($"""
                IF DB_ID(@database) IS NOT NULL
                BEGIN
                    ALTER DATABASE [{database}] SET SINGLE_USER WITH ROLLBACK IMMEDIATE;
                    DROP DATABASE [{database}];
                END;
                """, new { database });
            parent.Delete(true);
            config.OutputPath.Delete(true);
        }
    }
}
