using Docker.Common.TestInfrastructure;
using DotNet.Testcontainers.Networks;
using grate.Configuration;
using grate.Migration;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Hosting;
using Microsoft.Extensions.Logging;
using TestCommon.TestInfrastructure;

namespace Docker.Common;

// ReSharper disable once UnusedType.Global
public abstract class Startup<
    TTestContainerDatabase,
    TExternalDatabase,
    TGrateTestContext>: TestCommon.Startup<TTestContainerDatabase, TExternalDatabase, TGrateTestContext>
    where TTestContainerDatabase : ITestDatabase
    where TExternalDatabase : ITestDatabase
    where TGrateTestContext : IGrateTestContext 
{
    protected abstract DatabaseType DatabaseType { get; }
    
    protected override void ConfigureExtraServices(IServiceCollection services, HostBuilderContext context)
    {
        services.AddSingleton<IGrateMigrator>(provider =>
        {
            var configuration = provider.GetRequiredService<GrateTestConfig>();
            return new DockerGrateMigrator(
                DatabaseType, 
                provider.GetRequiredService<ILogger<DockerGrateMigrator>>(),
                provider.GetRequiredService<INetwork>(),
                configuration.ApplicationDockerImage ?? configuration.DefaultApplicationDockerImage);
        });
    }
    
    protected override GrateTestConfig ExtraConfiguration(GrateTestConfig config) 
        => config with {ConnectToDockerInternal = true};
}
