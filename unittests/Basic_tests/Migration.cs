using Basic_tests.Infrastructure;
using grate.Configuration;
using grate.Migration;
using TestCommon.TestInfrastructure;

namespace Basic_tests;

public class Migration
{
    private readonly MockGrateLogger  _logger;
    private readonly MockGrateLoggerFactory _loggerFactory;

    public Migration()
    {
        _logger = new MockGrateLogger();
        _loggerFactory = new MockGrateLoggerFactory(_logger);
    }

    [Fact]
    public async Task Does_not_output_qny_sql_run_in_dryrun_mode()
    {
        var dbMigrator = GetDbMigrator(true, baseline: false);
        var migrator = new GrateMigrator(_loggerFactory, dbMigrator);
        await migrator.Migrate();
        Assert.DoesNotContain(" No sql run, either an empty folder, or all files run against destination previously.", _logger.LoggedMessages);
    }

    [Fact]
    public async Task Outputs_no_sql_run_in_live_mode()
    {
        var dbMigrator = GetDbMigrator(false, baseline: false);
        var migrator = new GrateMigrator(_loggerFactory, dbMigrator);
        await migrator.Migrate();
        Assert.Contains(" No sql run, either an empty folder, or all files run against destination previously.", _logger.LoggedMessages);
    }

    [Fact]
    public async Task Outputs_baseline_info_in_baseline_mode()
    {
        var dbMigrator = GetDbMigrator(false, baseline: true);
        var migrator = new GrateMigrator(_loggerFactory, dbMigrator);
        await migrator.Migrate();
        Assert.Contains("Running a baseline run. No scripts will be actually be run, but the scripts will be marked as run.", _logger.LoggedMessages);
    }

    private static DirectoryInfo Wrap(DirectoryInfo root, string? subFolder) =>
        new(Path.Combine(root.ToString(), subFolder ?? ""));

    private static IDbMigrator GetDbMigrator(bool dryRun, bool baseline)
    {
        var parent = TestConfig.CreateRandomTempDirectory();
        var knownFolders = FoldersConfiguration.Default();

        var path = Wrap(parent, knownFolders[KnownFolderKeys.Up]!.Path);

        var folder1 = new DirectoryInfo(Path.Combine(path.ToString(), "01_sub", "folder", "long", "way"));
        string filename1 = "01_any_filename.sql";
        TestConfig.WriteContent(folder1, filename1, "Whatever");

        var configuration = new GrateConfiguration()
        {
            NonInteractive = true,
            SqlFilesDirectory = parent,
            DryRun = dryRun,
            Baseline = baseline
        };
        var dbMigrator = new MockDbMigrator() { Configuration = configuration };

        return dbMigrator;
    }

}
