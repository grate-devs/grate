using Basic_tests.Infrastructure;
using grate.Configuration;
using grate.Infrastructure;
using grate.Migration;
using NSubstitute;
using Dir = System.IO.Directory;


namespace Basic_tests.GrateMigrator_MigrationStatus;

// ReSharper disable once InconsistentNaming
public class MigrationStatus_ : IDisposable
{
    private static readonly DirectoryInfo SqlFilesDirectory = Dir.CreateTempSubdirectory();

    [Fact]
    public async Task Includes_list_of_ScriptsRun()
    {
        var grateMigrator = CreateMigrator(new List<(string, string)>()
        {
            ("script_that_is_run.sql", "-- ThisIsRun"),
            ("script_that_is_not_run.sql", "-- ThisIsNotRun"),
        });
        await grateMigrator.Migrate();

        Assert.NotNull(grateMigrator.MigrationResult);
        Assert.Equal("script_that_is_run.sql", Assert.Single(grateMigrator.MigrationResult.ScriptsRun));
    }

    private static GrateMigrator CreateMigrator(List<(string, string)> scripts)
    {
        foreach (var (filename, content) in scripts)
        {
            var parent = Path.Combine(SqlFilesDirectory.ToString(), "up");
            Directory.CreateDirectory(parent);

            var fullPath = Path.Combine(parent, filename);
            File.WriteAllText(fullPath, content);
        }

        var config = new GrateConfiguration()
        {
            SqlFilesDirectory = SqlFilesDirectory,
            NonInteractive = true,
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
        var grateMigrator = new GrateMigrator(new MockGrateLoggerFactory(), dbMigrator);

        return grateMigrator;
    }

    public void Dispose()
    {
        Directory.Delete(SqlFilesDirectory.FullName, true);
    }
}
