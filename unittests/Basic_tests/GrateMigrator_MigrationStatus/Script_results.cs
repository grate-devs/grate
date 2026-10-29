using Basic_tests.Infrastructure;
using grate.Configuration;
using grate.Infrastructure;
using grate.Migration;
using NSubstitute;

namespace Basic_tests.GrateMigrator_MigrationStatus;

public class Script_results : IDisposable
{
    private readonly DirectoryInfo _directory = Directory.CreateTempSubdirectory();

    [Theory]
    [InlineData(MigrationType.Once, "permissions", false, false)]
    [InlineData(MigrationType.Once, "permissions", true, false)]
    [InlineData(MigrationType.AnyTime, "permissions", false, false)]
    [InlineData(MigrationType.AnyTime, "permissions", true, false)]
    [InlineData(MigrationType.EveryTime, "up", false, true)]
    [InlineData(MigrationType.EveryTime, "up", true, true)]
    public async Task Up_to_date_check_uses_configured_migration_type_rather_than_folder_name(
        MigrationType type, string folderPath, bool dryRun, bool expectedUpToDate)
    {
        WriteScript($"{folderPath}/01_change.sql");
        var folders = new FoldersConfiguration(new MigrationsFolder("custom", folderPath, type));
        var (migrator, _) = CreateMigrator(dryRun, folders);

        await migrator.Migrate();

        // The documented check counts non-EveryTime scripts, including custom folders.
        Assert.Equal(expectedUpToDate, migrator.MigrationResult.IsUpToDate);
        Assert.Equal(["01_change.sql"], migrator.MigrationResult.ScriptsRun);
    }

    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public async Task Changed_anytime_script_stays_out_of_date_after_everytime_scripts_run(bool dryRun)
    {
        WriteScript("beforeMigration/01_prepare.sql");
        WriteScript("views/01_changed_view.sql");
        WriteScript("views/02_unchanged_view.sql");
        WriteScript("permissions/01_permissions.sql");
        WriteScript("afterMigration/01_finish.sql");
        var (migrator, dbMigrator) = CreateMigrator(dryRun);
        // Control the run/skip decisions to test aggregation, not history or hash comparison.
        dbMigrator.RunSql(
                Arg.Any<string>(), "02_unchanged_view.sql", Arg.Any<MigrationsFolder>(), Arg.Any<long>(),
                Arg.Any<GrateEnvironment>(), Arg.Any<ConnectionType>(), Arg.Any<TransactionHandling>())
            .Returns((SqlRun: false, HistoryRecorded: false));

        await migrator.Migrate();

        Assert.False(migrator.MigrationResult.IsUpToDate);
        Assert.Equal(
            ["01_prepare.sql", "01_changed_view.sql", "01_permissions.sql", "01_finish.sql"],
            migrator.MigrationResult.ScriptsRun);
    }

    [Theory]
    [InlineData(false, "release/01_change.sql")]
    [InlineData(true, "01_change.sql")]
    public async Task Nested_script_identity_is_consistent_in_dispatch_and_results(
        bool ignoreDirectoryNames, string expectedScriptName)
    {
        const string sql = "-- create a customer table";
        WriteScript("up/release/01_change.sql", sql);
        WriteScript("up/release/notes.txt", "This is documentation, not a migration.");
        var (migrator, dbMigrator) = CreateMigrator(ignoreDirectoryNames: ignoreDirectoryNames);

        await migrator.Migrate();

        // Characterizes the reported identity at this orchestration boundary; storage is replaced.
        Assert.Equal([expectedScriptName], migrator.MigrationResult.ScriptsRun);
        await dbMigrator.Received(1).RunSql(
            sql, expectedScriptName, Arg.Any<MigrationsFolder>(), Arg.Any<long>(),
            Arg.Any<GrateEnvironment>(), Arg.Any<ConnectionType>(), Arg.Any<TransactionHandling>());
        await dbMigrator.Received(1).RunSql(
            Arg.Any<string>(), Arg.Any<string>(), Arg.Any<MigrationsFolder>(), Arg.Any<long>(),
            Arg.Any<GrateEnvironment>(), Arg.Any<ConnectionType>(), Arg.Any<TransactionHandling>());
    }

    private (GrateMigrator Migrator, MockDbMigrator DbMigrator) CreateMigrator(
        bool dryRun = false, IFoldersConfiguration? folders = null, bool ignoreDirectoryNames = false)
    {
        var dbMigrator = Substitute.ForPartsOf<MockDbMigrator>();
        dbMigrator.Configuration = new GrateConfiguration
        {
            SqlFilesDirectory = _directory,
            OutputPath = new DirectoryInfo(Path.Combine(_directory.FullName, "output")),
            NonInteractive = true,
            DryRun = dryRun,
            UpToDateCheck = true,
            Folders = folders ?? FoldersConfiguration.Default(),
            IgnoreDirectoryNames = ignoreDirectoryNames
        };
        dbMigrator.RunSql(
                Arg.Any<string>(), Arg.Any<string>(), Arg.Any<MigrationsFolder>(), Arg.Any<long>(),
                Arg.Any<GrateEnvironment>(), Arg.Any<ConnectionType>(), Arg.Any<TransactionHandling>())
            .Returns((SqlRun: true, HistoryRecorded: !dryRun));

        return (new GrateMigrator(new MockGrateLoggerFactory(), dbMigrator), dbMigrator);
    }

    private void WriteScript(string relativePath, string sql = "-- migration")
    {
        var fullPath = Path.Combine(_directory.FullName, relativePath);
        Directory.CreateDirectory(Path.GetDirectoryName(fullPath)!);
        File.WriteAllText(fullPath, sql);
    }

    public void Dispose() => _directory.Delete(true);
}
