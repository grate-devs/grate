using grate.Configuration;
using BigQuery.TestInfrastructure;
using TestCommon.TestInfrastructure;

[assembly: Xunit.v3.Parallelization(Mode = Xunit.Sdk.ParallelMode.None)]

namespace Docker.BigQuery;

// ReSharper disable once UnusedType.Global
public class Startup: Docker.Common.Startup<BigQueryTestContainerDatabase, BigQueryExternalDatabase, BigQueryGrateTestContext>
{
    protected override DatabaseType DatabaseType => DatabaseType.BigQuery;
}
