using Dapper;
using grate.Configuration;
using grate.Exceptions;
using SqlServer.TestInfrastructure;
using TestCommon.Generic.Running_MigrationScripts;
using TestCommon.TestInfrastructure;
using static grate.Configuration.KnownFolderKeys;

namespace SqlServer.Reported_issues;

// ReSharper disable once InconsistentNaming
/// <summary>
/// Additional transaction/history coverage for #657, alongside the unchanged tests from #828.
/// </summary>
[Collection(nameof(SqlServerGrateTestContext))]
public class Transaction_history_follow_up(SqlServerGrateTestContext context, ITestOutputHelper testOutput) : MigrationsScriptsBase(context, testOutput)
{
    private const string ViewSql = @"
CREATE VIEW [myview] AS
SELECT 1 as [Number]";

    private const string PermissionsSql = @"
DROP USER IF EXISTS [myuser];
CREATE USER [myuser] WITHOUT LOGIN";

    [Theory]
    [InlineData(Permissions, false)]
    [InlineData(Permissions, true)]
    [InlineData(AfterMigration, false)]
    [InlineData(AfterMigration, true)]
    public async Task Autonomous_script_completes_with_a_new_or_previously_run_view(string folder, bool viewAlreadyRun)
    {
        var db = TestConfig.RandomDatabase();
        var parent = CreateRandomTempDirectory();
        var knownFolders = FoldersConfiguration.Default();
        var config = BuildConfig(db, parent, knownFolders);

        try
        {
            WriteSql(parent, knownFolders[Views]!.Path, "01.sql", ViewSql);
            if (viewAlreadyRun)
            {
                await Migrate(config);
            }

            WriteSql(parent, knownFolders[folder]!.Path, "Create.sql", PermissionsSql);
            await Migrate(config);

            using (var conn = Context.External.CreateDbConnection(db))
            {
                Assert.Equal(1, await conn.QuerySingleAsync<int>("SELECT [Number] FROM dbo.myview"));
                Assert.Equal(1, await conn.QuerySingleAsync<int>("SELECT COUNT(*) FROM sys.database_principals WHERE name = 'myuser'"));
                Assert.Equal(new[] { "01.sql", "Create.sql" }, await GetScriptsRun(db));
                Assert.Empty(await conn.QueryAsync<string>("SELECT script_name FROM grate.ScriptsRunErrors"));
                Assert.All(await conn.QueryAsync<string>("SELECT status FROM grate.[Version]"), status => Assert.Equal("Finished", status));
            }

            // The view is unchanged and must not rerun; autonomous folders still run every time.
            await Migrate(config);
            Assert.Equal(new[] { "01.sql", "Create.sql", "Create.sql" }, await GetScriptsRun(db));
        }
        finally
        {
            await Cleanup(db, parent, config);
        }
    }

    [Fact]
    public async Task A_failure_after_permissions_rolls_back_the_view_but_preserves_autonomous_effects_and_history()
    {
        var db = TestConfig.RandomDatabase();
        var parent = CreateRandomTempDirectory();
        var knownFolders = FoldersConfiguration.Default();
        var config = BuildConfig(db, parent, knownFolders);

        try
        {
            WriteSql(parent, knownFolders[Views]!.Path, "01.sql", ViewSql);
            WriteSql(parent, knownFolders[Permissions]!.Path, "Create.sql", PermissionsSql);
            WriteSql(parent, knownFolders[AfterMigration]!.Path, "Fail.sql", "THROW 50000, 'Expected failure after permissions', 1;");

            await using (var migrator = Context.Migrator.WithConfiguration(config))
            {
                var failure = await Assert.ThrowsAsync<MigrationFailed>(migrator.Migrate);
                Assert.Contains("Expected failure after permissions", failure.ToString());
            }

            using var conn = Context.External.CreateDbConnection(db);
            Assert.Null(await conn.QuerySingleAsync<int?>("SELECT OBJECT_ID('dbo.myview', 'V')"));
            Assert.Equal(1, await conn.QuerySingleAsync<int>("SELECT COUNT(*) FROM sys.database_principals WHERE name = 'myuser'"));
            Assert.Equal(new[] { "Create.sql" }, await GetScriptsRun(db));
            Assert.Equal("Fail.sql", Assert.Single(await conn.QueryAsync<string>("SELECT script_name FROM grate.ScriptsRunErrors")));
            Assert.Equal("Error", Assert.Single(await conn.QueryAsync<string>("SELECT status FROM grate.[Version]")));
        }
        finally
        {
            await Cleanup(db, parent, config);
        }
    }

    [Fact]
    public async Task Retrying_the_same_migrator_reruns_one_time_scripts_rolled_back_by_a_later_failure()
    {
        var db = TestConfig.RandomDatabase();
        var parent = CreateRandomTempDirectory();
        var knownFolders = FoldersConfiguration.Default();
        var config = BuildConfig(db, parent, knownFolders);

        try
        {
            WriteSql(parent, knownFolders[Up]!.Path, "001.sql", "CREATE TABLE dbo.RetryProbe (Id int); INSERT INTO dbo.RetryProbe VALUES (1);");
            WriteSql(parent, knownFolders[Views]!.Path, "01.sql", "THROW 50000, 'Expected failure before retry', 1;");

            await using var migrator = Context.Migrator.WithConfiguration(config);
            await Assert.ThrowsAsync<MigrationFailed>(migrator.Migrate);

            using (var conn = Context.External.CreateDbConnection(db))
            {
                Assert.Null(await conn.QuerySingleAsync<int?>("SELECT OBJECT_ID('dbo.RetryProbe', 'U')"));
                Assert.Empty(await GetScriptsRun(db));
            }

            WriteSql(parent, knownFolders[Views]!.Path, "01.sql", ViewSql);
            await migrator.Migrate();

            using (var conn = Context.External.CreateDbConnection(db))
            {
                Assert.NotNull(await conn.QuerySingleAsync<int?>("SELECT OBJECT_ID('dbo.RetryProbe', 'U')"));
                Assert.Equal(1, Assert.Single(await conn.QueryAsync<int>("SELECT Id FROM dbo.RetryProbe")));
                Assert.Equal(1, await conn.QuerySingleAsync<int>("SELECT [Number] FROM dbo.myview"));
                Assert.Equal(new[] { "001.sql", "01.sql" }, await GetScriptsRun(db));
            }
        }
        finally
        {
            await Cleanup(db, parent, config);
        }
    }

    private GrateConfiguration BuildConfig(string db, DirectoryInfo parent, IFoldersConfiguration knownFolders) =>
        GrateConfigurationBuilder.Create(Context.DefaultConfiguration)
            .WithConnectionString(Context.ConnectionString(db))
            .WithFolders(knownFolders)
            .WithSqlFilesDirectory(parent)
            .WithTransaction()
            .Build() with
            {
                // Keep script commands bounded during the regression.
                CommandTimeout = 10
            };

    private async Task Migrate(GrateConfiguration config)
    {
        await using var migrator = Context.Migrator.WithConfiguration(config);
        await migrator.Migrate();
    }

    private async Task<string[]> GetScriptsRun(string db)
    {
        using var conn = Context.External.CreateDbConnection(db);
        return (await conn.QueryAsync<string>("SELECT script_name FROM grate.ScriptsRun ORDER BY id")).ToArray();
    }

    private async Task Cleanup(string db, DirectoryInfo parent, GrateConfiguration config)
    {
        try
        {
            await Context.DropDatabase(db);
        }
        finally
        {
            parent.Delete(true);
            config.OutputPath.Delete(true);
        }
    }
}
