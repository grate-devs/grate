using Dapper;
using FluentAssertions;
using FluentAssertions.Execution;
using grate.Configuration;
using grate.Migration;
using TestCommon.TestInfrastructure;
using static grate.Configuration.KnownFolderKeys;

namespace TestCommon.Generic.Running_MigrationScripts;

// ReSharper disable once InconsistentNaming
public abstract class Versioning_The_Database(IGrateTestContext context, ITestOutputHelper testOutput) 
    : MigrationsScriptsBase(context, testOutput)
{
    protected Versioning_The_Database(): this(null!, null!)
    {
    }
    
    [Fact]
    [Trait("Category", "Versioning")]
    public async Task Returns_the_new_version_id()
    {
        var db = TestConfig.RandomDatabase();

        var parent = CreateRandomTempDirectory();
        var knownFolders = Folders.Default;
        CreateDummySql(parent, knownFolders[Sprocs]);
        
        var config = GrateConfigurationBuilder.Create(Context.DefaultConfiguration)
            .WithConnectionString(Context.ConnectionString(db))
            .WithFolders(knownFolders)
            .WithSqlFilesDirectory(parent)
            .Build();
        
        await using (var migrator = Context.Migrator.WithConfiguration(config))
        {
            await migrator.Migrate();

            using (new AssertionScope())
            {
                // Version again
                var version = await migrator.GetDbMigrator().VersionTheDatabase("1.2.3.4");
                version.Should().Be(2);

                // And again
                version = await migrator.GetDbMigrator().VersionTheDatabase("1.2.3.4");
                version.Should().Be(3);
            }
        }
        
        //await Context.DropDatabase(db);
    }

    [Fact]
    [Trait("Category", "Versioning")]
    public async Task Does_not_create_versions_on_DryRun()
    {
        //for bug #204 - when running --baseline and --dryrun on a new db it shouldn't create the grate schema's etc
        var db = TestConfig.RandomDatabase();

        var parent = CreateRandomTempDirectory();
        var knownFolders = Folders.Default;

        CreateDummySql(parent, knownFolders[Sprocs]); // make sure there's something that could be logged...

        var config = GrateConfigurationBuilder.Create(Context.DefaultConfiguration)
            .WithConnectionString(Context.ConnectionString(db))
            .WithSqlFilesDirectory(parent)
            .Baseline()  // don't run the sql
            .DryRun()  // and don't actually _touch_ the DB in any way
            .Build();

        await using var migrator = Context.Migrator.WithConfiguration(config);
        await migrator.Migrate(); // shouldn't touch anything because of --dryrun
        var addedTable = await migrator.GetDbMigrator().Database.VersionTableExists();
        addedTable.Should().Be(false); // we didn't even add the grate infrastructure
        
        //await Context.DropDatabase(db);
    }

    [Fact]
    [Trait("Category", "Versioning")]
    public async Task Creates_a_new_version_with_status_InProgress()
    {
        var db = TestConfig.RandomDatabase();
        var dbVersion = "1.2.3.4";

        var parent = CreateRandomTempDirectory();
        var knownFolders = Folders.Default;
        CreateDummySql(parent, knownFolders[Up]);

        long newVersionId = 0;
        
        var config = GrateConfigurationBuilder.Create(Context.DefaultConfiguration)
            .WithConnectionString(Context.ConnectionString(db))
            .WithFolders(knownFolders)
            .WithSqlFilesDirectory(parent)
            .Build();

        await using (var migrator = Context.Migrator.WithConfiguration(config))
        {
            //Calling migrate here to setup the database and such.
            await migrator.Migrate();
            newVersionId = await migrator.GetDbMigrator().VersionTheDatabase(dbVersion);
        }

        IEnumerable<(string version, string status)> entries;
        string sql = $"SELECT version, status FROM {Context.Syntax.TableWithSchema("grate", "Version")}";

        using (var conn = Context.CreateDbConnection(db))
        {
            entries = (await conn.QueryAsync<(string version, string status)>(sql)).ToArray();
        }

        entries.Should().HaveCount(2);
        var version = entries.Single(x => x.version == dbVersion);
        version.status.Should().Be(MigrationStatus.InProgress);
        
        //await Context.DropDatabase(db);
    }
        
    [Fact]
    [Trait("Category", "Versioning")]
    public async Task Migrating_creates_a_new_version_record()
    {
        var db = TestConfig.RandomDatabase();
        var dbVersion = "1.2.3.1";

        var parent = CreateRandomTempDirectory();
        var knownFolders = Folders.Default;
        CreateDummySql(parent, knownFolders[Up]);

        var config = GrateConfigurationBuilder.Create(Context.DefaultConfiguration)
            .WithConnectionString(Context.ConnectionString(db))
            .WithFolders(knownFolders)
            .WithSqlFilesDirectory(parent)
            .WithVersion(dbVersion)
            .Build();

        await using (var migrator = Context.Migrator.WithConfiguration(config))
        {
            await migrator.Migrate();
        }

        IEnumerable<(string version, string status)> entries;
        string sql = $"SELECT version, status FROM {Context.Syntax.TableWithSchema("grate", "Version")}";

        using (var conn = Context.CreateDbConnection(db))
        {
            entries = (await conn.QueryAsync<(string version, string status)>(sql)).ToArray();
        }

        entries.Should().HaveCount(1);
        var version = entries.Single();
        version.version.Should().Be(dbVersion);
        version.status.Should().Be(MigrationStatus.Finished);
    }
    
    [Fact]
    [Trait("Category", "Versioning")]
    public async Task Migrating_creates_a_new_version_record_even_in_baseline_mode()
    {
        var db = TestConfig.RandomDatabase();
        var dbVersion = "1.2.3.4";

        var parent = CreateRandomTempDirectory();
        var knownFolders = Folders.Default;
        CreateDummySql(parent, knownFolders[Up]);

        var config = GrateConfigurationBuilder.Create(Context.DefaultConfiguration)
            .WithConnectionString(Context.ConnectionString(db))
            .WithFolders(knownFolders)
            .WithSqlFilesDirectory(parent)
            .WithVersion(dbVersion)
            .Baseline()
            .Build();

        await using (var migrator = Context.Migrator.WithConfiguration(config))
        {
            await migrator.Migrate();
        }

        IEnumerable<(string version, string status)> entries;
        string sql = $"SELECT version, status FROM {Context.Syntax.TableWithSchema("grate", "Version")}";

        using (var conn = Context.CreateDbConnection(db))
        {
            entries = (await conn.QueryAsync<(string version, string status)>(sql)).ToArray();
        }

        entries.Should().HaveCount(1);
        var version = entries.Single();
        version.version.Should().Be(dbVersion);
        version.status.Should().Be(MigrationStatus.Finished);
    }
    
    [Fact]
    [Trait("Category", "Versioning")]
    public async Task Includes_RepositoryPath_in_version_table()
    {
        var db = TestConfig.RandomDatabase();
        var dbVersion = "1.2.3.4";

        var parent = CreateRandomTempDirectory();
        var knownFolders = Folders.Default;
        CreateDummySql(parent, knownFolders[Up]);

        var repositoryPath = "any repository path";
        var config = GrateConfigurationBuilder.Create(Context.DefaultConfiguration)
            .WithConnectionString(Context.ConnectionString(db))
            .WithFolders(knownFolders)
            .WithSqlFilesDirectory(parent)
            .WithRepositoryPath(repositoryPath)
            .WithVersion(dbVersion)
            .Build();

        await using (var migrator = Context.Migrator.WithConfiguration(config))
        {
            //Calling migrate here to setup the database and such.
            await migrator.Migrate();
        }

        string? loggedRepositoryPath;
        string sql = $"SELECT repository_path FROM {Context.Syntax.TableWithSchema("grate", "Version")}";

        using (var conn = Context.CreateDbConnection(db))
        {
            loggedRepositoryPath = await conn.QuerySingleOrDefaultAsync<string>(sql);
        }

        loggedRepositoryPath.Should().Be(repositoryPath);
        
        //await Context.DropDatabase(db);
    }
    

    [Fact]
    [Trait("Category", "Versioning")]
    [Trait("Bug", "388")]
    public virtual async Task Does_not_create_versions_when_no_scripts_exist()
    {
        var database = TestConfig.RandomDatabase();
        var sqlFolder = CreateRandomTempDirectory();
        var newVersion = "1.0.0.0-alpha";
        
        var config = GrateConfigurationBuilder.Create(Context.DefaultConfiguration)
            .WithConnectionString(Context.ConnectionString(database))
            .WithVersion(newVersion)
            .WithSqlFilesDirectory(sqlFolder)
            .Build();
        
        await using var migrator = Context.Migrator.WithConfiguration(config);
        await migrator.Migrate();
        var currentVersion = await migrator.GetDbMigrator().Database.GetCurrentVersion();
        currentVersion.Should().NotBe(newVersion);
        currentVersion.Should().Be(AnsiSqlDatabase.NotVersioning);
        
        await Context.DropDatabase(database);
    }

    [Fact]
    [Trait("Category", "Versioning")]
    [Trait("Bug", "388")]
    public async Task Does_not_create_versions_when_no_script_changed()
    {
        //for bug #388 - no script change, should not create new version entry
        var sqlFolder = CreateRandomTempDirectory();
        var knownFolders = Folders.Default;
        CreateDummySql(sqlFolder, knownFolders[Up]);
        var originalVersion = "1.0.0.0-alpha";

        var db = TestConfig.RandomDatabase();
        
        var config = GrateConfigurationBuilder.Create(Context.DefaultConfiguration)
            .WithConnectionString(Context.ConnectionString(db))
            .WithSqlFilesDirectory(sqlFolder)
            .WithVersion(originalVersion)
            .Build();
        
        GrateConfiguration newConfig;

        await using (var migrator = Context.Migrator.WithConfiguration(config))
        {
            await migrator.Migrate();

            newConfig = GrateConfigurationBuilder.Create(Context.DefaultConfiguration)
                // important: should be use the same database as with previous run.
                .WithConnectionString(migrator.GetDbMigrator().Configuration.ConnectionString!)
                .WithAdminConnectionString(migrator.GetDbMigrator().Configuration.AdminConnectionString!)
                .WithSqlFilesDirectory(sqlFolder)
                .WithVersion("1.0.0.2")
                .Build();
        }

        await using var newMigrator = Context.Migrator.WithConfiguration(newConfig);

        // migrate again, but don't change the script, shouldn't create a new version record
        await newMigrator.Migrate();

        var currentVersion = await newMigrator.GetDbMigrator().Database.GetCurrentVersion();
        currentVersion.Should()
            .Be(originalVersion, "DB version should not be changed due to no new script detected");

        //await Context.DropDatabase(db);
    }

    [Fact]
    [Trait("Category", "Versioning")]
    [Trait("Bug", "388")]
    public async Task Should_set_the_version_table_to_new_version_value_when_migrating()
    {
        var sqlFolder = CreateRandomTempDirectory();
        var knownFolders = Folders.Default;
        CreateDummySql(sqlFolder, knownFolders[Up], "1_up.sql");
        
        var config = GrateConfigurationBuilder.Create(Context.DefaultConfiguration)
            .WithConnectionString(Context.ConnectionString(TestConfig.RandomDatabase()))
            .WithSqlFilesDirectory(sqlFolder)
            .WithVersion("1.0.0.1")
            .Build();

        GrateConfiguration newConfig;
        await using (var migrator = Context.Migrator.WithConfiguration(config))
        {
            await migrator.Migrate();

            CreateDummySql(sqlFolder, knownFolders[Sprocs], "2_sproc.sql");
        
            newConfig = GrateConfigurationBuilder.Create(Context.DefaultConfiguration)
                .WithSqlFilesDirectory(sqlFolder)
                // important: should be use the same database as with previous run.
                .WithConnectionString(migrator.GetDbMigrator().Configuration.ConnectionString!)
                .WithAdminConnectionString(migrator.GetDbMigrator().Configuration.AdminConnectionString!)
                .WithVersion("1.0.0.2")
                .Build();
        }

        await using var newMigrator = Context.Migrator.WithConfiguration(newConfig);
        await newMigrator.Migrate();

        var currentVersion = await newMigrator.GetDbMigrator().Database.GetCurrentVersion();
        currentVersion.Should().Be(newConfig.Version, "DB version should be changed to the latest version");
    }

}
