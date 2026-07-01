using System.Collections.Immutable;
using grate.Configuration;
using grate.Infrastructure;
using Microsoft.Extensions.DependencyInjection;
using static TestCommon.Generic.Running_MigrationScripts.MigrationsScriptsBase;
namespace Basic_tests.DependencyInjection;

// ReSharper disable once InconsistentNaming
public class GrateConfigurationBuilder_Factory
{
    [Fact]
    public void Creates_default_builder_with_non_interactive()
    {
        var builder = GrateConfigurationBuilder.Create();
        var grateConfiguration = builder.Build();
        Assert.True(grateConfiguration.NonInteractive);
    }

    [Theory]
    [InlineData("./temp")] // unix relative path
    public void Creates_default_builder_with_output_folder(string outputFolder)
    {
        var outputDir = Directory.CreateDirectory(outputFolder);
        WriteSql(Wrap(outputDir, "views"), "01_test_view.sql", "create view v_test as select 1");
        var builder = GrateConfigurationBuilder.Create();
        builder.WithOutputFolder(outputFolder);
        var grateConfiguration = builder.Build();
        Assert.NotNull(grateConfiguration.OutputPath);
        Assert.Equal(outputDir.FullName, grateConfiguration.OutputPath.FullName, ignoreCase: true);
        Directory.Delete(outputFolder, true);
    }

    [Theory]
    [InlineData("./sql")] // unix relative path
    public void Creates_default_builder_with_sql_folder(string sqlFolder)
    {
        var sqlDir = Directory.CreateDirectory(sqlFolder);
        WriteSql(Wrap(sqlDir, "views"), "01_test_view.sql", "create view v_test as select 1");
        var builder = GrateConfigurationBuilder.Create();
        builder.WithSqlFilesDirectory(sqlFolder);
        var grateConfiguration = builder.Build();
        Assert.NotNull(grateConfiguration.SqlFilesDirectory);
        Assert.Equal(sqlDir.FullName, grateConfiguration.SqlFilesDirectory.FullName, ignoreCase: true);
        Directory.Delete(sqlFolder, true);
    }
    [Theory]
    [InlineData("grate")]
    [InlineData("roundhouse")]
    public void Creates_default_builder_with_schema(string schemaName)
    {
        var builder = GrateConfigurationBuilder.Create();
        builder.WithSchema(schemaName);
        var grateConfiguration = builder.Build();
        Assert.Equal(schemaName, grateConfiguration.SchemaName);
    }

    [Theory]
    [InlineData("Data source=whatever;Initial Catalog=;")]
    [InlineData("Data source=whatever;Database=;")]
    public void Creates_default_builder_with_connection_string(string connectionString)
    {
        var builder = GrateConfigurationBuilder.Create();
        builder.WithConnectionString(connectionString);
        var grateConfiguration = builder.Build();
        Assert.Equal(connectionString, grateConfiguration.ConnectionString);
    }

    [Theory]
    [InlineData("Data source=whatever;Initial Catalog=master;")]
    [InlineData("Data source=whatever;Database=master;")]
    public void Creates_default_builder_with_admin_connection_string(string adminConnectionString)
    {
        var builder = GrateConfigurationBuilder.Create();
        builder.WithAdminConnectionString(adminConnectionString);
        var grateConfiguration = builder.Build();
        Assert.Equal(adminConnectionString, grateConfiguration.AdminConnectionString);
    }

    [Theory]
    [InlineData("1.0.0-beta1")] //semver
    [InlineData("1.0.0.0")]
    public void Creates_default_builder_with_version(string version)
    {
        var builder = GrateConfigurationBuilder.Create();
        builder.WithVersion(version);
        var grateConfiguration = builder.Build();
        Assert.Equal(version, grateConfiguration.Version);
    }
    
    [Fact]
    public void Creates_default_builder_with_do_not_create_database()
    {
        var builder = GrateConfigurationBuilder.Create();
        builder.DoNotCreateDatabase();
        var grateConfiguration = builder.Build();
        Assert.False(grateConfiguration.CreateDatabase);
    }

    [Fact]
    public void Creates_default_builder_with_transaction()
    {
        var builder = GrateConfigurationBuilder.Create();
        builder.WithTransaction();
        var grateConfiguration = builder.Build();
        Assert.True(grateConfiguration.Transaction);
    }

    [Theory]
    [InlineData("dev")]
    [InlineData("test")]
    [InlineData("uat")]
    [InlineData("prod")]
    public void Creates_default_builder_with_environment_name(string environmentName)
    {
        var serviceCollection = new ServiceCollection();
        var builder = GrateConfigurationBuilder.Create();
        builder.WithEnvironment(environmentName);
        var grateConfiguration = builder.Build();
        Assert.NotNull(grateConfiguration.Environment);
        Assert.Equivalent(new GrateEnvironment(environmentName), grateConfiguration.Environment);
    }
    
    [Fact]
    public void Creates_default_builder_with_custom_folder_configuration()
    {
        var builder = GrateConfigurationBuilder.Create()
                        .WithFolders(Folders.Create("up=ddl", "views=binoculars"));
        var grateConfiguration = builder.Build();

        var folders = grateConfiguration.Folders!;
        Assert.Equal(Folders.Default.Count, folders.Count);

        Assert.Equal("ddl", folders[KnownFolderKeys.Up]!.Path);
        Assert.Equal("binoculars", folders[KnownFolderKeys.Views]!.Path);
    }
    
}
