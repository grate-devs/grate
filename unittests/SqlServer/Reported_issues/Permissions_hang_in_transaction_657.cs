using Dapper;
using grate.Configuration;
using SqlServer.TestInfrastructure;
using TestCommon.Generic.Running_MigrationScripts;
using TestCommon.TestInfrastructure;
using static grate.Configuration.KnownFolderKeys;

namespace SqlServer.Reported_issues;

// ReSharper disable once InconsistentNaming
/// <summary>
/// #657: With --trx, a script in an autonomous folder (permissions) hangs on its ScriptsRun insert
/// if any script in a transactional folder (views) has been run before it. The transactional
/// connection holds locks on the ScriptsRun table until commit, and the permissions folder writes
/// to that table from a separate connection.
/// </summary>
[Collection(nameof(SqlServerGrateTestContext))]
public class Permissions_hang_in_transaction_657(SqlServerGrateTestContext context, ITestOutputHelper testOutput) : MigrationsScriptsBase(context, testOutput)
{
    private const string ViewSql = @"
CREATE VIEW [myview] AS
SELECT 1 as [Number]";

    private const string PermissionsSql = @"
DROP USER IF EXISTS [myuser];
CREATE USER [myuser] WITHOUT LOGIN";

    [Fact]
    public async Task Permissions_script_completes_when_a_view_was_run_in_the_same_migration()
    {
        var db = TestConfig.RandomDatabase();
        var parent = CreateRandomTempDirectory();
        var knownFolders = FoldersConfiguration.Default();

        WriteSql(parent, knownFolders[Views]!.Path, "01.sql", ViewSql);
        WriteSql(parent, knownFolders[Permissions]!.Path, "Create.sql", PermissionsSql);

        var config = BuildConfig(db, parent, knownFolders);

        await using (var migrator = Context.Migrator.WithConfiguration(config))
        {
            await migrator.Migrate();
        }

        var scripts = await GetScriptsRun(db);
        Assert.Contains("01.sql", scripts);
        Assert.Contains("Create.sql", scripts);
    }

    [Fact]
    public async Task Permissions_script_completes_when_a_view_was_run_in_an_earlier_migration()
    {
        var db = TestConfig.RandomDatabase();
        var parent = CreateRandomTempDirectory();
        var knownFolders = FoldersConfiguration.Default();

        WriteSql(parent, knownFolders[Views]!.Path, "01.sql", ViewSql);

        var config = BuildConfig(db, parent, knownFolders);

        await using (var migrator = Context.Migrator.WithConfiguration(config))
        {
            await migrator.Migrate();
        }

        // Second run: the view is already recorded, only the permissions script is new
        WriteSql(parent, knownFolders[Permissions]!.Path, "Create.sql", PermissionsSql);

        await using (var migrator = Context.Migrator.WithConfiguration(config))
        {
            await migrator.Migrate();
        }

        var scripts = await GetScriptsRun(db);
        Assert.Contains("Create.sql", scripts);
    }

    private GrateConfiguration BuildConfig(string db, DirectoryInfo parent, IFoldersConfiguration knownFolders) =>
        GrateConfigurationBuilder.Create(Context.DefaultConfiguration)
            .WithConnectionString(Context.ConnectionString(db))
            .WithFolders(knownFolders)
            .WithSqlFilesDirectory(parent)
            .WithTransaction()
            .Build() with
            {
                // Keep a regression short instead of waiting for the default lock timeout
                CommandTimeout = 10
            };

    private async Task<string[]> GetScriptsRun(string db)
    {
        var sql = $"SELECT script_name FROM {Context.Syntax.TableWithSchema("grate", "ScriptsRun")}";
        using var conn = Context.External.CreateDbConnection(db);
        return (await conn.QueryAsync<string>(sql)).ToArray();
    }
}
