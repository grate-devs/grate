using CommandLine.Common.TestInfrastructure;
using grate.Configuration;
using grate.Migration;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Hosting;
using TestCommon.TestInfrastructure;

namespace CommandLine.Common;

// ReSharper disable once UnusedType.Global
public abstract class Startup<
    TTestContainerDatabase,
    TExternalDatabase,
    TGrateTestContext> : TestCommon.Startup<TTestContainerDatabase, TExternalDatabase, TGrateTestContext>
    where TTestContainerDatabase : ITestDatabase
    where TExternalDatabase : ITestDatabase
    where TGrateTestContext : IGrateTestContext
{
    protected abstract DatabaseType DatabaseType { get; }

    protected override void ConfigureExtraServices(IServiceCollection services, HostBuilderContext context)
    {
        services.AddSingleton<IGrateMigrator>(new CommandLineGrateMigrator(DatabaseType));
    }
}
