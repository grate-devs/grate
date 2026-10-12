using grate.Configuration;
using BigQuery.TestInfrastructure;
using TestCommon.TestInfrastructure;

[assembly: CollectionBehavior(DisableTestParallelization = true)]

namespace CommandLine.BigQuery;

// ReSharper disable once UnusedType.Global
public class Startup: Common.Startup<BigQueryTestContainerDatabase, BigQueryExternalDatabase, BigQueryGrateTestContext>
{
    protected override DatabaseType DatabaseType => DatabaseType.BigQuery;
}
