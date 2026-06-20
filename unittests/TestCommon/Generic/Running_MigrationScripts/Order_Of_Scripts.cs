using Dapper;
using FluentAssertions;
using FluentAssertions.Execution;
using grate.Configuration;
using grate.Migration;
using TestCommon.TestInfrastructure;
using static grate.Configuration.KnownFolderKeys;

namespace TestCommon.Generic.Running_MigrationScripts;

// ReSharper disable once InconsistentNaming
public abstract class Order_Of_Scripts(IGrateTestContext context, ITestOutputHelper testOutput) 
    : MigrationsScriptsBase(context, testOutput)
{
    protected Order_Of_Scripts(): this(null!, null!)
    {
    }
    
    [Fact]
    public async Task Is_as_expected()
    {
        var db = TestConfig.RandomDatabase();

        IGrateMigrator? migrator;
        await using (migrator = GetMigrator(db, true))
        {
            await migrator.Migrate();
        }

        string[] scripts;
        string sql = $"SELECT script_name FROM {Context.Syntax.TableWithSchema("grate", "ScriptsRun")} ORDER BY id";

        using (var conn = Context.External.CreateDbConnection(db))
        {
            scripts = (await conn.QueryAsync<string>(sql)).ToArray();
        }

        var expectation = new[]
        {
            "1_beforemigration.sql",
            "1_alterdatabase.sql",
            "1_aftercreate.sql",
            "1_beforeup.sql",
            "1_up.sql",
            "1_firstafterup.sql",
            "1_functions.sql",
            "1_views.sql",
            "1_sprocs.sql",
            "1_triggers.sql",
            "1_indexes.sql",
            "1_afterotherany.sql",
            "1_permissions.sql",
            "1_aftermigration.sql",
        };

        scripts.Should().BeEquivalentTo(expectation);
        scripts.Should().HaveCount(14);

        using (new AssertionScope())
        {
            for (int i = 0; i < expectation.Length; i++)
            {
                scripts[i].Should().Be(expectation[i]);
            }
        }
    }


    private IGrateMigrator GetMigrator(string databaseName, bool createDatabase)
    {
        var scriptsDir = CreateRandomTempDirectory();

        var config = Context.DefaultConfiguration with
        {
            CreateDatabase = createDatabase,
            ConnectionString = Context.ConnectionString(databaseName),
            Folders = Folders.Default,
            SqlFilesDirectory = scriptsDir
        };

        var knownFolders = config.Folders;

        CreateDummySql(scriptsDir, knownFolders[AfterMigration], "1_aftermigration.sql");
        CreateDummySql(scriptsDir, knownFolders[AlterDatabase], "1_alterdatabase.sql");
        CreateDummySql(scriptsDir, knownFolders[BeforeMigration], "1_beforemigration.sql");
        CreateDummySql(scriptsDir, knownFolders[Functions], "1_functions.sql");
        CreateDummySql(scriptsDir, knownFolders[Indexes], "1_indexes.sql");
        CreateDummySql(scriptsDir, knownFolders[Permissions], "1_permissions.sql");
        CreateDummySql(scriptsDir, knownFolders[RunAfterCreateDatabase], "1_aftercreate.sql");
        CreateDummySql(scriptsDir, knownFolders[RunAfterOtherAnyTimeScripts], "1_afterotherany.sql");
        CreateDummySql(scriptsDir, knownFolders[RunBeforeUp], "1_beforeup.sql");
        CreateDummySql(scriptsDir, knownFolders[RunFirstAfterUp], "1_firstafterup.sql");
        CreateDummySql(scriptsDir, knownFolders[Sprocs], "1_sprocs.sql");
        CreateDummySql(scriptsDir, knownFolders[Triggers], "1_triggers.sql");
        CreateDummySql(scriptsDir, knownFolders[Up], "1_up.sql");
        CreateDummySql(scriptsDir, knownFolders[Views], "1_views.sql");

        return Context.Migrator.WithConfiguration(config);

    }
}
