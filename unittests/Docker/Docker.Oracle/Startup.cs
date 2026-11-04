using grate.Configuration;
using Oraclde.TestInfrastructure;
using Oracle.TestInfrastructure;
using TestCommon.TestInfrastructure;

[assembly: Xunit.v3.Parallelization(Mode = Xunit.Sdk.ParallelMode.None)]

namespace Docker.Oracle;

// ReSharper disable once UnusedType.Global
public class Startup: Common.Startup<OracleTestContainerDatabase, OracleExternalDatabase, OracleGrateTestContext>
{
    protected override DatabaseType DatabaseType => DatabaseType.Oracle;
}
