using grate.Configuration;
using grate.Migration;
using SqlServer.TestInfrastructure;
using TestCommon.Generic.Running_MigrationScripts;
using TestCommon.TestInfrastructure;
using static grate.Configuration.KnownFolderKeys;

namespace SqlServer.Reported_issues;

// ReSharper disable once InconsistentNaming
/// <summary>
/// Issues that have been encountered in the real world.
/// Create tests to reproduce the issue and then fix the issue, and keep the test to ensure it doesn't regress.
/// </summary>
[Collection(nameof(SqlServerGrateTestContext))]
public class Run_after_create_database_232(SqlServerGrateTestContext context, ITestOutputHelper testOutput) : MigrationsScriptsBase(context, testOutput)
{
    private const string Bug232Sql = @"
ALTER DATABASE {{DatabaseName}} SET ALLOW_SNAPSHOT_ISOLATION ON;
ALTER DATABASE {{DatabaseName}} SET READ_COMMITTED_SNAPSHOT ON";

    /// <summary>
    /// Regression in 1.4.0 made us disable connection pooling if not explicitly set in the connection string.
    /// however, this makes connections a lot slower, especially if using Azure AD authentication, where obtaining
    /// the token takes a while. Disabling pooling means we have to get the token every time we open a connection,
    /// as the connection is actually closed, not just returned to the pool.
    ///
    /// To run the "RunAfterCreateDatabase" scripts in its own transaction from the command line, use the following:
    /// 
    /// --folders=runAfterCreateDatabase=transactionHandling:autonomous
    /// 
    /// </summary>
    /// <exception cref="Exception"></exception>
    [Fact]
    public async Task Bug232_Timeout_v1U002E4U002E0_Regression()
    {
        // V1.4 regressed something, trying to repro

        var db = TestConfig.RandomDatabase();

        var parent = CreateRandomTempDirectory();
        var knownFolders = FoldersConfiguration.Default();

        // Use autonomous transactions for the RunAfterCreateDatabase folder makes this work without having to 
        // disable connection pooling
        knownFolders[RunAfterCreateDatabase] = knownFolders[RunAfterCreateDatabase]! with { TransactionHandling = TransactionHandling.Autonomous };

        var path = new DirectoryInfo(Path.Combine(parent.ToString(), knownFolders[RunAfterCreateDatabase]?.Path ?? throw new Exception("Config Fail")));

        WriteSql(path, "token.sql", Bug232Sql);

        var config = GrateConfigurationBuilder.Create(Context.DefaultConfiguration)
            .WithConnectionString(Context.ConnectionString(db))
            .WithFolders(knownFolders)
            .WithSqlFilesDirectory(parent)
            .Build();

        await using (var migrator = Context.Migrator.WithConfiguration(config))
        {
            await migrator.Migrate();
        }

        // Now drop it and do it again
        config = config with
        {
            Drop = true
        };

        await using (var migrator = Context.Migrator.WithConfiguration(config))
        {
            await migrator.Migrate();
        }

        //await Context.DropDatabase(db);
    }

}
