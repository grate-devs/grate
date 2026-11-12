using Dapper;
using Microsoft.Data.SqlClient;
using SqlServer.TestInfrastructure;
using TestCommon.TestInfrastructure;

namespace SqlServer.Fixture;

[Collection(nameof(SqlServerGrateTestContext))]
public sealed class Scoped_pooling_connections(SqlServerGrateTestContext context)
{
    [Fact]
    public async Task A_case_reuses_target_sessions_and_clearing_requires_a_new_session()
    {
        Assert.SkipUnless(context.TestDatabase is SqlServerTestContainerDatabase,
            "Scoped pooling controls require the disposable SQL Server fixture.");
        IGrateTestContext host = context;
        var database = TestConfig.RandomDatabase();
        var optedIn = bool.TryParse(Environment.GetEnvironmentVariable("GRATE_SQLSERVER_SCOPED_POOLING"), out var value) && value;
        Assert.Equal(optedIn, new SqlConnectionStringBuilder(host.ConnectionString(database)).Pooling);
        Assert.False(new SqlConnectionStringBuilder(host.AdminConnectionString).Pooling);
        Assert.False(new SqlConnectionStringBuilder(host.UserConnectionString(database)).Pooling);
        using var scope = SqlServerScopedPooling.BeginCase(true);
        using var admin = host.CreateAdminDbConnection();
        try
        {
            await admin.ExecuteAsync(host.Syntax.CreateDatabase(database, null));
            var connectionString = host.ConnectionString(database);
            var first = await OpenAndRead(connectionString);
            var second = await OpenAndRead(connectionString);
            Assert.NotEqual(Guid.Empty, first);
            Assert.Equal(first, second);

            SqlConnection.ClearAllPools();
            var afterClear = await OpenAndRead(connectionString);
            Assert.NotEqual(Guid.Empty, afterClear);
            Assert.NotEqual(first, afterClear);
        }
        finally
        {
            SqlConnection.ClearAllPools();
            await host.DropDatabase(database);
        }
    }

    [Fact]
    public async Task A_missing_database_probe_does_not_cache_login_failure_after_creation()
    {
        Assert.SkipUnless(context.TestDatabase is SqlServerTestContainerDatabase,
            "Scoped pooling controls require the disposable SQL Server fixture.");
        IGrateTestContext host = context;
        var database = TestConfig.RandomDatabase();
        using var scope = SqlServerScopedPooling.BeginCase(true);
        var connectionString = host.ConnectionString(database);
        Assert.Equal(PoolBlockingPeriod.NeverBlock, new SqlConnectionStringBuilder(connectionString).PoolBlockingPeriod);
        using var admin = host.CreateAdminDbConnection();
        try
        {
            await using (var missing = new SqlConnection(connectionString))
            {
                await Assert.ThrowsAsync<SqlException>(() => missing.OpenAsync(TestContext.Current.CancellationToken));
            }
            await admin.ExecuteAsync(host.Syntax.CreateDatabase(database, null));

            // Confirm server readiness independently, with no pool-clearing or
            // sleep between the failed pooled probe and its successful retry.
            var unpooled = new SqlConnectionStringBuilder(connectionString) { Pooling = false };
            await using var ready = new SqlConnection(unpooled.ConnectionString);
            await ready.OpenAsync(TestContext.Current.CancellationToken);
            Assert.NotEqual(Guid.Empty, await OpenAndRead(connectionString));
        }
        finally
        {
            SqlConnection.ClearAllPools();
            await host.DropDatabase(database);
        }
    }

    private static async Task<Guid> OpenAndRead(string connectionString)
    {
        await using var connection = new SqlConnection(connectionString);
        await connection.OpenAsync(TestContext.Current.CancellationToken);
        Assert.Equal(1, await connection.QuerySingleAsync<int>("SELECT 1;", commandTimeout: 5));
        return connection.ClientConnectionId;
    }
}
