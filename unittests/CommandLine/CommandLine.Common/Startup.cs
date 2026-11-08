using CommandLine.Common.TestInfrastructure;
using grate.Configuration;
using grate.Migration;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Hosting;

namespace CommandLine.Common;

// ReSharper disable once UnusedType.Global
public abstract class Startup : TestCommon.Startup
{
    protected abstract DatabaseType DatabaseType { get; }

    protected override void ConfigureExtraServices(IServiceCollection services, HostBuilderContext context)
    {
        services.AddSingleton<IGrateMigrator>(new CommandLineGrateMigrator(DatabaseType));
    }
}
