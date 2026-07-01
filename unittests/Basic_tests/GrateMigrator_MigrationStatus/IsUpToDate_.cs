using Basic_tests.Infrastructure;
using grate.Configuration;
using grate.Infrastructure;
using grate.Migration;
using NSubstitute;
using Dir = System.IO.Directory;
namespace Basic_tests.GrateMigrator_MigrationStatus;

// ReSharper disable once InconsistentNaming
public class IsUpToDate_ : IDisposable
{
    private static readonly DirectoryInfo SqlFilesDirectory = Dir.CreateTempSubdirectory();

    [Theory]
    [InlineData(true)]
    [InlineData(false)]
    public async Task False_if_scripts_run(bool dryRun)
    {
        var folders = new Dictionary<string, List<(string, string)>>
        {
            { "up",
                [
                    ("script_that_is_run.sql", "-- ThisIsRun"),
                    ("script_that_is_not_run.sql", "-- ThisIsNotRun")
                ]
            }
        };

        var grateMigrator = CreateMigrator(folders, dryRun);
        await grateMigrator.Migrate();

        Assert.NotNull(grateMigrator.MigrationResult);
        Assert.False(grateMigrator.MigrationResult.IsUpToDate);

        Assert.Contains("Up to date: False", _logger.LoggedMessages);
        Assert.Contains("Changed script: script_that_is_run.sql", _logger.LoggedMessages);
    }

    [Theory]
    [InlineData(true)]
    [InlineData(false)]
    public async Task True_if_no_scripts_run(bool dryRun)
    {
        var folders = new Dictionary<string, List<(string, string)>>
        {
            { "up",
                [
                    ("script_that_is_not_run_either.sql", "-- ThisIsDefinitelyNotRun"),
                    ("script_that_is_not_run.sql", "-- ThisIsNotRun")
                ]
            }
        };

        var grateMigrator = CreateMigrator(folders, dryRun);
        await grateMigrator.Migrate();

        Assert.NotNull(grateMigrator.MigrationResult);
        Assert.True(grateMigrator.MigrationResult.IsUpToDate);
    }

    [Theory]
    [InlineData(true)]
    [InlineData(false)]
    public async Task True_if_only_everytime_scripts_run(bool dryRun)
    {
        var folders = new Dictionary<string, List<(string, string)>>
        {
            { "up",
                [
                    ("script_that_is_not_run_either.sql", "-- ThisIsDefinitelyNotRun"),
                    ("script_that_is_not_run.sql", "-- ThisIsNotRun")
                ]
            },
            { "permissions",
                [
                    ("script_that_is_run.sql", "-- ThisIsRun"),
                    ("script_that_is_not_run.sql", "-- ThisIsNotRun")
                ]
            }
        };

        var grateMigrator = CreateMigrator(folders, dryRun);
        await grateMigrator.Migrate();

        Assert.NotNull(grateMigrator.MigrationResult);
        Assert.True(grateMigrator.MigrationResult.IsUpToDate);
    }

    private GrateMigrator CreateMigrator(Dictionary<string, List<(string, string)>> scripts, bool dryRun)
    {
        foreach (var folder in scripts.Keys)
        {
            foreach (var (filename, content) in scripts[folder])
            {
                var parent = Path.Combine(SqlFilesDirectory.ToString(), folder);
                Directory.CreateDirectory(parent);

                var fullPath = Path.Combine(parent, filename);
                File.WriteAllText(fullPath, content);
            }
        }

        var config = new GrateConfiguration()
        {
            SqlFilesDirectory = SqlFilesDirectory,
            NonInteractive = true,
            DryRun = dryRun,
            UpToDateCheck = true
        };

        var dbMigrator = Substitute.ForPartsOf<MockDbMigrator>();
        dbMigrator.RunSql(
                Arg.Any<string>(),
                Arg.Any<string>(),
                Arg.Any<MigrationsFolder>(),
                Arg.Any<long>(),
                Arg.Any<GrateEnvironment>(),
                Arg.Any<ConnectionType>(),
                Arg.Any<TransactionHandling>()
            )
            .Returns(info =>
            {
                var sql = info.ArgAt<string>(0);
                return sql.Contains("ThisIsRun");
            });

        dbMigrator.Configuration = config;
        var grateMigrator = new GrateMigrator(new MockGrateLoggerFactory(_logger), dbMigrator);

        return grateMigrator;
    }

    private readonly MockGrateLogger _logger = new();

    public void Dispose()
    {
        Directory.Delete(SqlFilesDirectory.FullName, true);
    }
}
