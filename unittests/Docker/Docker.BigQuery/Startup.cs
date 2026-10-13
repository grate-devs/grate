using grate.Configuration;
using BigQuery.TestInfrastructure;
using TestCommon.TestInfrastructure;

[assembly: CollectionBehavior(DisableTestParallelization = true)]

namespace Docker.BigQuery;

// ReSharper disable once UnusedType.Global
public class Startup: Docker.Common.Startup<BigQueryTestContainerDatabase, BigQueryExternalDatabase, BigQueryGrateTestContext>
{
    protected override DatabaseType DatabaseType => DatabaseType.BigQuery;
}
