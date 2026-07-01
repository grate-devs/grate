using grate.Configuration;
using grate.DependencyInjection;
using grate.Infrastructure;
using grate.Migration;
using grate.SqlServer.Migration;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Logging;
using TestCommon.TestInfrastructure;
namespace Basic_tests;

// ReSharper disable once InconsistentNaming
public class GrateConfiguration_
{
    [Theory]
    [InlineData("Data source=Monomonojono;Initial Catalog=Øyenbryn;Lotsastuff", "Data source=Monomonojono;Initial Catalog=master;Lotsastuff")]
    [InlineData("Data source=Monomonojono;Database=Øyenbryn;Lotsastuff", "Data source=Monomonojono;Database=master;Lotsastuff")]
    public void Uses_ConnectionString_with_master_db_if_adminConnectionString_is_not_set_Initial_Catalog(string connectionString, string expectedAdminConnectionString)
    {
        var serviceProvider = new ServiceCollection()
           .AddLogging(opt =>
           {
               opt.AddConsole();
               opt.SetMinimumLevel(TestConfig.GetLogLevel());
           })
           .AddGrate(builder =>
           {
               builder
                   .WithConnectionString(connectionString);
           })
           .UseDatabase<SqlServerDatabase>()
           .BuildServiceProvider();
        var cfg = serviceProvider.GetRequiredService<GrateConfiguration>();
        var database = serviceProvider.GetService<IDatabase>()!;
        var adminConnectionString = database.GetAdminConnectionString(cfg);
        Assert.Equal(expectedAdminConnectionString, adminConnectionString);
    }

    [Fact]
    public void Doesnt_include_comma_in_drop_folder()
    {
        // For bug #40
        var serviceProvider = new ServiceCollection()
           .AddLogging(opt =>
           {
               opt.AddConsole();
               opt.SetMinimumLevel(TestConfig.GetLogLevel());
           })
           .AddGrate(builder =>
           {
               builder
                   .WithConnectionString("Data source=localhost,1433;Initial Catalog=Øyenbryn;");
           })
           .UseDatabase<SqlServerDatabase>()
           .BuildServiceProvider();
        var cfg = serviceProvider.GetRequiredService<GrateConfiguration>();
        var db = serviceProvider.GetService<IDatabase>()!;
        db.InitializeConnections(cfg);
        var dropFolder = GrateMigrator.ChangeDropFolder(cfg, db.ServerName, db.DatabaseName);

        Assert.DoesNotContain(",", dropFolder);
    }

}
