using System.Data.Common;
using Dapper;
using FluentAssertions;
using grate.Configuration;
using grate.DependencyInjection;
using grate.Infrastructure;
using grate.Migration;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Logging;
using TestCommon.Generic.Running_MigrationScripts;
using TestCommon.TestInfrastructure;
using static grate.Configuration.KnownFolderKeys;

namespace TestCommon.DependencyInjection;

public abstract class GrateServiceCollectionTest(IGrateTestContext context)
{
    protected IGrateTestContext Context { get; } = context;

    protected abstract string BigintType { get; }
    protected abstract string VarcharType { get; }

    private void ConfigureService(GrateConfigurationBuilder grateConfigurationBuilder)
    {
        var connectionString = Context.ConnectionString(TestConfig.RandomDatabase());
        var adminConnectionString = Context.AdminConnectionString;

        grateConfigurationBuilder
            .WithConnectionString(connectionString)
            .WithAdminConnectionString(adminConnectionString);
    }



    [Fact]
    public void Should_inject_all_necessary_services_to_container()
    {
        var serviceCollection = new ServiceCollection();
        serviceCollection
            .AddGrate(ConfigureService)
            .UseDatabase(Context.DatabaseType);

        ValidateService(serviceCollection, typeof(IGrateMigrator), ServiceLifetime.Transient, typeof(GrateMigrator));
        ValidateService(serviceCollection, typeof(IDbMigrator), ServiceLifetime.Transient, typeof(DbMigrator));
        ValidateService(serviceCollection, typeof(IHashGenerator), ServiceLifetime.Transient, typeof(HashGenerator));
        ValidateService(serviceCollection, typeof(IDatabase), ServiceLifetime.Transient, Context.DatabaseType);
    }

    [Fact]
    public async Task Should_migrate_database_successfully()
    {
        var sqlFolder = MigrationsScriptsBase.CreateRandomTempDirectory();
        var serviceCollection = new ServiceCollection();
        serviceCollection.AddLogging(opt =>
        {
            opt.AddConsole();
            opt.SetMinimumLevel(TestConfig.GetLogLevel());
        });
        serviceCollection.AddGrate(builder =>
        {
            builder.WithSqlFilesDirectory(sqlFolder);
            ConfigureService(builder);
        })
        .UseDatabase(Context.DatabaseType);
        var serviceProvider = serviceCollection.BuildServiceProvider();
        var syntax = Context.Syntax;
        var tableName = CreateMigrationScript(sqlFolder, syntax);

        var scope = serviceProvider.CreateScope();

        var provider = scope.ServiceProvider;
        var grateConfiguration = provider.GetRequiredService<GrateConfiguration>();

        const int maxTries = 10;

        await using (var grateMigrator = provider.GetService<IGrateMigrator>())
        {
            var numberOfTries = 0;
            do
            {
                try
                {
                    await grateMigrator!.Migrate();
                    break;
                }
                catch (DbException)
                {
                    await Task.Delay(100, TestContext.Current.CancellationToken);
                }
            } while (numberOfTries++ < maxTries);
        }

        string sql =
            $"SELECT script_name FROM {syntax.TableWithSchema("grate", "ScriptsRun")} where script_name like '{tableName}_%'";

        int tries = 0;

        string[] scripts = [];
        FileInfo[] files = [];

        do
        {
            try
            {
                using var conn = Context.GetDbConnection(grateConfiguration.ConnectionString!);
                scripts = (await conn.QueryAsync<string>(sql)).ToArray();
                files = sqlFolder.GetFiles("*.sql", SearchOption.AllDirectories);
            }
            catch (DbException)
            {
                await Task.Delay(100, TestContext.Current.CancellationToken);
            }
        } while (tries++ < maxTries);

        scripts.Should().HaveCount(files.Length);
    }

    protected void ValidateService(IServiceCollection serviceCollection, Type serviceType, ServiceLifetime lifetime, Type? expectedImplementationType = null)
    {
        serviceCollection.Should().ContainSingle(x => x.ServiceType == serviceType);
        var service = serviceCollection.Single(x => x.ServiceType == serviceType);
        service.Lifetime.Should().Be(lifetime);
        if (expectedImplementationType is not null)
        {
            service.ImplementationType.Should().Be(expectedImplementationType);
        }
    }

    [Fact]
    public void Should_throw_invalid_operation_exception_when_no_database_is_configured()
    {
        var serviceCollection = new ServiceCollection()
            .AddLogging()
            .AddGrate();
        var serviceProvider = serviceCollection.BuildServiceProvider();
        Action action = () => serviceProvider.GetService<IGrateMigrator>();
        action.Should().Throw<InvalidOperationException>("You forgot to configure the database. Please .UseXXX on the grate configuration.");
    }

    protected virtual string CreateMigrationScript(DirectoryInfo sqlFolder, ISyntax syntax)
    {
        var knownFolders = FoldersConfiguration.Default();
        var tableName = "grate_test";
        var create_table = @$"
                        CREATE TABLE {tableName} (
                            id {BigintType} NOT NULL PRIMARY KEY,
                            name {VarcharType}(255) NOT NULL
                        )";
        MigrationsScriptsBase.WriteSql(sqlFolder, knownFolders[Up]!.Path, $"{tableName}_001_create_test_table.sql", create_table);
        var insert_test_data = @$"
                            INSERT INTO {tableName}(id, name) VALUES (1, 'test')
                            ";
        MigrationsScriptsBase.WriteSql(sqlFolder, knownFolders[RunFirstAfterUp]!.Path, $"{tableName}_001_insert_test_data.sql", insert_test_data);
        return tableName;
    }
}
