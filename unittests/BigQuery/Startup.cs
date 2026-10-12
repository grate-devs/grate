using BigQuery.TestInfrastructure;
using grate.bigquery.DependencyInjection;
using grate.DependencyInjection;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Hosting;

[assembly: CollectionBehavior(DisableTestParallelization = true)]

namespace BigQuery;

// ReSharper disable once UnusedType.Global
public class Startup: TestCommon.Startup<BigQueryTestContainerDatabase, BigQueryExternalDatabase, BigQueryGrateTestContext>
{
    protected override void ConfigureExtraServices(IServiceCollection services, HostBuilderContext context)
    {
        services
            .AddGrate()
            .UseBigQuery();
    }
}
