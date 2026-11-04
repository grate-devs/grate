using grate.DependencyInjection;
using grate.sqlite.DependencyInjection;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Hosting;
using Sqlite.TestInfrastructure;
using TestCommon.TestInfrastructure;

[assembly: Xunit.v3.Parallelization(Mode = Xunit.Sdk.ParallelMode.None)]

namespace Sqlite;

// ReSharper disable once UnusedType.Global
public class Startup: TestCommon.Startup<SqliteTestDatabase, SqliteTestDatabase, SqliteGrateTestContext>
{
    protected override void ConfigureExtraServices(IServiceCollection services, HostBuilderContext context)
    {
        services
            .AddGrate()
            .UseSqlite();
    }
}
