using Dapper;
using grate.Configuration;
using Oracle.ManagedDataAccess.Client;
using Oracle.TestInfrastructure;
using TestCommon.Generic.Running_MigrationScripts;
using TestCommon.TestInfrastructure;
using static grate.Configuration.KnownFolderKeys;

namespace Oracle.Running_MigrationScripts;

[Collection(nameof(OracleGrateTestContext))]
public sealed class PooledDatabaseDrop(OracleGrateTestContext context, ITestOutputHelper output)
    : MigrationsScriptsBase(context, output)
{
    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public async Task Drop_and_recreate_preserves_other_users_pools(bool pooling)
    {
        var database = TestConfig.RandomDatabase().ToUpperInvariant();
        var otherUser = TestConfig.RandomDatabase().ToUpperInvariant();
        var connectionString = ExplicitPooling(Context.ConnectionString(database), pooling);
        var resultConnectionString = ExplicitPooling(Context.External.ConnectionString(database), pooling);
        var otherConnectionString = ExplicitPooling(Context.External.ConnectionString(otherUser), true, 1);
        var adminPool = ExplicitPooling(Context.External.AdminConnectionString, true, 1);
        var directory = CreateRandomTempDirectory();
        CreateDummySql(directory, Folders.Default[Sprocs]);
        var configuration = GrateConfigurationBuilder.Create(Context.DefaultConfiguration)
            .WithConnectionString(connectionString)
            .WithSqlFilesDirectory(directory)
            .DropDatabase()
            .Build();
        await using var admin = new OracleConnection(ExplicitPooling(Context.External.AdminConnectionString, false));
        await admin.OpenAsync(TestContext.Current.CancellationToken);
        try
        {
            await admin.ExecuteAsync(Context.Syntax.CreateDatabase(otherUser,
                new OracleConnectionStringBuilder(otherConnectionString).Password));
            var otherSession = await Session(otherConnectionString);
            var adminSession = await Session(adminPool);
            await using var otherConnection = new OracleConnection(otherConnectionString);
            await otherConnection.OpenAsync(TestContext.Current.CancellationToken);
            await using (var migrator = Context.Migrator.WithConfiguration(configuration))
            {
                await migrator.Migrate();
            }
            await Snapshot(admin, database, "BeforeSecondMigration");
            WriteSomeOtherSql(directory, Folders.Default[Sprocs]);
            try
            {
                await using var migrator = Context.Migrator.WithConfiguration(configuration);
                await migrator.Migrate();
            }
            catch (OracleException exception)
            {
                TestOutput.WriteLine($"DropFailureNumber={exception.Number}");
                await Snapshot(admin, database, "AfterFailedSecondMigration");
                throw;
            }

            await using (var connection = new OracleConnection(resultConnectionString))
            {
                var scripts = (await connection.QueryAsync<string>(
                    $"SELECT text_of_script FROM {Context.Syntax.TableWithSchema("grate", "ScriptsRun")}")).ToArray();
                Assert.Single(scripts);
                Assert.Equal(Context.Syntax.CurrentDatabase, scripts[0]);
            }
            Assert.Equal(otherSession, await otherConnection.QuerySingleAsync<string>(
                "SELECT SYS_CONTEXT('USERENV', 'SESSIONID') FROM dual"));
            await otherConnection.CloseAsync();
            Assert.Equal(otherSession, await Session(otherConnectionString));
            Assert.Equal(adminSession, await Session(adminPool));
        }
        finally
        {
            using (var connection = new OracleConnection(adminPool))
            {
                OracleConnection.ClearPool(connection);
            }
            foreach (var item in new[] { (database, resultConnectionString), (otherUser, otherConnectionString) })
            {
                using var connection = new OracleConnection(item.Item2);
                OracleConnection.ClearPool(connection);
                if (await admin.ExecuteScalarAsync<int>("SELECT COUNT(*) FROM all_users WHERE username = :name",
                        new { name = item.Item1 }) != 0)
                {
                    await admin.ExecuteAsync(Context.Syntax.DropDatabase(item.Item1));
                }
            }
        }
    }

    private static string ExplicitPooling(string connectionString, bool pooling, int maximumPoolSize = 4) =>
        new OracleConnectionStringBuilder(connectionString)
        {
            Pooling = pooling,
            MinPoolSize = 0,
            MaxPoolSize = maximumPoolSize
        }.ConnectionString;

    private static async Task<string> Session(string connectionString)
    {
        await using var connection = new OracleConnection(connectionString);
        return await connection.QuerySingleAsync<string>("SELECT SYS_CONTEXT('USERENV', 'SESSIONID') FROM dual");
    }

    private async Task Snapshot(OracleConnection admin, string database, string phase)
    {
        var sessions = await admin.QueryAsync<SessionObservation>(
            "SELECT sid, serial# AS SerialNumber, status FROM v$session WHERE username = :name",
            new { name = database });
        foreach (var session in sessions)
        {
            TestOutput.WriteLine($"{phase}: SID={session.Sid};Serial={session.SerialNumber};Status={session.Status}");
        }
    }

    private sealed class SessionObservation
    {
        public int Sid { get; set; }
        public int SerialNumber { get; set; }
        public string Status { get; set; } = "";
    }
}
