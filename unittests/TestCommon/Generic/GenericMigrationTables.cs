using Dapper;
using grate.Configuration;
using grate.Exceptions;
using TestCommon.TestInfrastructure;
using static grate.Configuration.KnownFolderKeys;

namespace TestCommon.Generic;


public abstract class GenericMigrationTables(IGrateTestContext context, ITestOutputHelper testOutput)
{
    protected GenericMigrationTables(): this(null!, null!)
    {
    }

    protected IGrateTestContext Context { get; init; } = context;
    public ITestOutputHelper TestOutput { get; init; } = testOutput;

    [Theory]
    [InlineData("ScriptsRun")]
    [InlineData("ScriptsRunErrors")]
    [InlineData("Version")]
    public async Task Is_created_if_it_does_not_exist(string tableName)
    {
        var db = TestConfig.RandomDatabase();
        var fullTableName = Context.Syntax.TableWithSchema("grate", tableName);

        var parent = TestConfig.CreateRandomTempDirectory();
        var knownFolders = Folders.Default;

        var config = GrateConfigurationBuilder.Create(Context.DefaultConfiguration)
            .WithConnectionString(Context.ConnectionString(db))
            .WithFolders(knownFolders)
            .WithSqlFilesDirectory(parent)
            .Build();
        
        await using (var migrator = Context.Migrator.WithConfiguration(config))
        {
            await migrator.Migrate();
        }

        IEnumerable<string> scripts;
        string sql = $"SELECT modified_date FROM {fullTableName}";

        using (var conn = Context.GetDbConnection(Context.ConnectionString(db)))
        {
            scripts = await conn.QueryAsync<string>(sql);
        }
        Assert.NotNull(scripts);
    }

    [Theory]
    [InlineData("ScriptsRun")]
    [InlineData("ScriptsRunErrors")]
    [InlineData("Version")]
    public async Task Is_created_even_if_scripts_fail(string tableName)
    {
        var db = TestConfig.RandomDatabase()[..6] + "Failing";
        var fullTableName = Context.Syntax.TableWithSchema("grate", tableName);

        var parent = TestConfig.CreateRandomTempDirectory();
        var knownFolders = Folders.Default;
        CreateInvalidSql(parent, knownFolders[KnownFolderKeys.Up]);
        
        var config = GrateConfigurationBuilder.Create(Context.DefaultConfiguration)
            .WithConnectionString(Context.ConnectionString(db))
            .WithFolders(knownFolders)
            .WithSqlFilesDirectory(parent)
            .Build();
        
        await using (var migrator = Context.Migrator.WithConfiguration(config))
        {
            var ex = await Assert.ThrowsAsync<MigrationFailed>(migrator.Migrate);
        }


        IEnumerable<string> scripts;
        string sql = $"SELECT modified_date FROM {fullTableName}";

        using (var conn = Context.GetDbConnection(Context.ConnectionString(db)))
        {
            scripts = await conn.QueryAsync<string>(sql);
        }
        Assert.NotNull(scripts);
    }

    // [Theory]
    // [InlineData("ScriptsRun")]
    // [InlineData("ScriptsRunErrors")]
    // [InlineData("Version")]
    //public async Task Migration_does_not_fail_if_table_already_exists(string tableName)
    [Fact]
    public async Task Migration_does_not_fail_if_table_already_exists()
    {
        var db = "MonoBonoJono";

        var parent = TestConfig.CreateRandomTempDirectory();
        var knownFolders = Folders.Default;
        
        var config = GrateConfigurationBuilder.Create(Context.DefaultConfiguration)
            .WithConnectionString(Context.ConnectionString(db))
            .WithFolders(knownFolders)
            .WithSqlFilesDirectory(parent)
            .Build();

        await using (var migrator = Context.Migrator.WithConfiguration(config))
        {
            await migrator.Migrate();
        }

        // Run migration again - make sure it does not throw an exception
        await using (var migrator = Context.Migrator.WithConfiguration(config))
        {
            var exception = await Record.ExceptionAsync(() => migrator.Migrate());
            Assert.Null(exception);
        }
    }

    [Theory]
    [InlineData("version")]
    [InlineData("vErSiON")]
    public async Task Does_not_create_Version_table_if_it_exists_with_another_casing(string existingTable)
    {
        await CheckTableCasing("Version", existingTable, (config, name) => config with { VersionTableName = name });
    }
    [Theory]
    [InlineData("scriptsrun")]
    [InlineData("SCRiptSrUN")]
    public async Task Does_not_create_ScriptsRun_table_if_it_exists_with_another_casing(string existingTable)
    {
        await CheckTableCasing("ScriptsRun", existingTable, (config, name) => config with { ScriptsRunTableName = name });
    }
    [Theory]
    [InlineData("scriptsrunerrors")]
    [InlineData("ScripTSRunErrors")]
    public async Task Does_not_create_ScriptsRunErrors_table_if_it_exists_with_another_casing(string existingTable)
    {
        await CheckTableCasing("ScriptsRunErrors", existingTable, (config, name) => config with { ScriptsRunErrorsTableName = name });
    }

    protected virtual async Task CheckTableCasing(string tableName, string funnyCasing, Func<GrateConfiguration, string, GrateConfiguration> setTableName)
    {
        var db = TestConfig.RandomDatabase();

        var parent = TestConfig.CreateRandomTempDirectory();
        var knownFolders = FoldersConfiguration.Default();

        // Set the version table name to be lower-case first, and run one migration.

        var config = GrateConfigurationBuilder.Create(Context.DefaultConfiguration)
            .WithConnectionString(Context.ConnectionString(db))
            .WithFolders(knownFolders)
            .WithSqlFilesDirectory(parent)
            .Build();

        config = setTableName(config, funnyCasing);

        await using (var migrator = Context.Migrator.WithConfiguration(config))
        {
            await migrator.Migrate();
        }

        // Check that the table is indeed created with lower-case
        var errorCaseCountAfterFirstMigration = await TableCountIn(db, funnyCasing);
        var normalCountAfterFirstMigration = await TableCountIn(db, tableName);
        Assert.Multiple(() =>
        {
            Assert.Equal(1, errorCaseCountAfterFirstMigration);
            Assert.Equal(0, normalCountAfterFirstMigration);
        });

        // Run migration again - make sure it does not create the table with different casing too
        setTableName(config, tableName);
        await using (var migrator = Context.Migrator.WithConfiguration(config))
        {
            await migrator.Migrate();
        }

        var errorCaseCountAfterSecondMigration = await TableCountIn(db, funnyCasing);
        var normalCountAfterSecondMigration = await TableCountIn(db, tableName);
        Assert.Multiple(() =>
        {
            Assert.Equal(1, errorCaseCountAfterSecondMigration);
            Assert.Equal(0, normalCountAfterSecondMigration);
        });
        
        //await Context.DropDatabase(db);

    }

    private async Task<int> TableCountIn(string db, string tableName)
    {
        var schemaName = Context.DefaultConfiguration.SchemaName;
        var supportsSchemas = Context.SupportsSchemas;

        var fullTableName = supportsSchemas ? tableName : Context.Syntax.TableWithSchema(schemaName, tableName);
        var tableSchema = supportsSchemas ? schemaName : db;

        int count;
        string countSql = CountTableSql(tableSchema, fullTableName);

        using (var conn = Context.GetDbConnection(Context.ConnectionString(db)))
        {
            count = await conn.ExecuteScalarAsync<int>(countSql);
        }

        return count;
    }

    [Fact]
    public async Task Inserts_version_in_version_table()
    {
        var db = "BooYaTribe";

        var parent = TestConfig.CreateRandomTempDirectory();
        var knownFolders = Folders.Default;
        
        var config = GrateConfigurationBuilder.Create(Context.DefaultConfiguration)
            .WithConnectionString(Context.ConnectionString(db))
            .WithFolders(knownFolders)
            .WithSqlFilesDirectory(parent)
            .Build();

        CreateDummySql(parent, knownFolders[Sprocs]);
        await using (var migrator = Context.Migrator.WithConfiguration(config))
        {
            await migrator.Migrate();
        }

        IEnumerable<(string version, string status)> entries;
        string sql = $"SELECT version, status FROM {Context.Syntax.TableWithSchema("grate", "Version")}";

        using (var conn = Context.GetDbConnection(Context.ConnectionString(db)))
        {
            entries = await conn.QueryAsync<(string version, string status)>(sql);
        }

        var versions = entries.ToList();
        Assert.Single(versions);
        var version = versions.Single();
        Assert.Equal("a.b.c.d", version.version);
        // Validate the version is finished after running without errors
        Assert.Equal(MigrationStatus.Finished, version.status);
        
        //await Context.DropDatabase(db);
    }

    private static void CreateInvalidSql(DirectoryInfo root, MigrationsFolder? folder)
    {
        var dummySql = "SELECT TOP";
        var path = MakeSurePathExists(root, folder);
        WriteSql(path, "2_failing.sql", dummySql);
    }
    private void CreateDummySql(DirectoryInfo root, MigrationsFolder? folder)
    {
        var dummySql = Context.Sql.SelectVersion;
        var path = MakeSurePathExists(root, folder);
        WriteSql(path, "2_success.sql", dummySql);
    }

    private static void WriteSql(DirectoryInfo path, string filename, string? sql)
    {
        File.WriteAllText(Path.Combine(path.ToString(), filename), sql);
    }

    private static DirectoryInfo MakeSurePathExists(DirectoryInfo root, MigrationsFolder? folder)
        => MakeSurePathExists(Wrap(root, folder?.Path));

    protected static DirectoryInfo MakeSurePathExists(DirectoryInfo? path)
    {
        ArgumentNullException.ThrowIfNull(path);
        if (!path.Exists)
        {
            path.Create();
        }
        return path;
    }

    private static DirectoryInfo Wrap(DirectoryInfo root, string? relativePath) => TestConfig.Wrap(root, relativePath);

    protected virtual string CountTableSql(string schemaName, string tableName)
    {
        return $@"
SELECT count(table_name) FROM INFORMATION_SCHEMA.TABLES
WHERE 
table_schema = '{schemaName}' AND
table_name = '{tableName}'
";
    }

}
