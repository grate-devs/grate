using grate.DependencyInjection;
using grate.sqlserver.DependencyInjection;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.DependencyInjection.Extensions;
using Microsoft.Extensions.Hosting;
using SqlServerCaseSensitive.TestInfrastructure;
using TestCommon;

namespace SqlServerCaseSensitive;

// ReSharper disable once UnusedType.Global
public class Startup : Startup<SqlServerTestContainerDatabase, SqlServerExternalDatabase, SqlServerCaseSensitiveGrateTestContext>
{
    protected override void ConfigureExtraServices(IServiceCollection services, HostBuilderContext context)
    {
        services
            .AddGrate()
            .UseSqlServer();

        services.TryAddTransient<InspectableSqlServerDatabase>();
    }
}
