using Dapper;
using grate.Configuration;
using grate.Exceptions;
using Oracle.TestInfrastructure;
using TestCommon.TestInfrastructure;
using static grate.Configuration.KnownFolderKeys;

namespace CommandLine.Oracle.Running_MigrationScripts;

[Collection(nameof(OracleGrateTestContext))]
// ReSharper disable once InconsistentNaming
public class One_time_scripts(OracleGrateTestContext testContext, ITestOutputHelper testOutput)
    : TestCommon.Generic.Running_MigrationScripts.One_time_scripts(testContext, testOutput)
{
    protected override string CreateView1 => base.CreateView1 + " FROM DUAL";
    protected override string CreateView2 => base.CreateView2 + " FROM DUAL";
    
    [Fact]
    public override async Task Fails_if_changed_between_runs()
    {
        var db = TestConfig.RandomDatabase();

        var parent = CreateRandomTempDirectory();
        var knownFolders = Folders.Default;
        CreateDummySql(parent, knownFolders[Up]);

        var config = GrateConfigurationBuilder.Create(Context.DefaultConfiguration)
            .WithConnectionString(Context.ConnectionString(db))
            .WithFolders(knownFolders)
            .WithSqlFilesDirectory(parent)
            .Build();

        await using (var migrator = Context.Migrator.WithConfiguration(config))
        {
            await migrator.Migrate();
        }

        WriteSomeOtherSql(parent, knownFolders[Up]);

        await using (var migrator = Context.Migrator.WithConfiguration(config))
        {
            var ex = await Assert.ThrowsAsync<MigrationFailed>(() => migrator.Migrate());
        }

        string[] scripts;
        string sql = $"SELECT text_of_script FROM {Context.Syntax.TableWithSchema("grate", "ScriptsRun")}";

        using (var conn = Context.CreateDbConnection(db))
        {
            scripts = (await conn.QueryAsync<string>(sql)).ToArray();
        }

        Assert.Single(scripts);
        Assert.Equal(Context.Sql.SelectVersion, scripts.First());
        
        //await Context.DropDatabase(db);
    }

}


