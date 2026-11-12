using grate.DependencyInjection;
using grate.sqlserver.DependencyInjection;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.DependencyInjection.Extensions;
using Microsoft.Extensions.Hosting;
using SqlServer.TestInfrastructure;
using SqlServer.Diagnostics;

[assembly: Xunit.v3.Parallelization(Mode = Xunit.Sdk.ParallelMode.None)]
[assembly: SqlServerProfileTest]

namespace SqlServer;

// ReSharper disable once UnusedType.Global
public class Startup : TestCommon.Startup<SqlServerTestContainerDatabase, SqlServerExternalDatabase, SqlServerGrateTestContext>
{
    public Startup() => SqlServerProfile.StartFromEnvironment();

    protected override void ConfigureExtraServices(IServiceCollection services, HostBuilderContext context)
    {
        // Match TestCommon.Startup's fixture selection. External fixtures retain
        // their connection strings and pool state even if opt-in is inherited.
        SqlServerScopedPooling.ConfigureFixture(context.Configuration["GrateTestConfig:AdminConnectionString"] is null);
        services
            .AddGrate()
            .UseSqlServer();

        services.TryAddTransient<InspectableSqlServerDatabase>();
    }
}
