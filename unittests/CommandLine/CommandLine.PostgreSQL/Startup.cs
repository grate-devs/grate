using grate.Configuration;
using PostgreSQL.TestInfrastructure;
using TestCommon.TestInfrastructure;

[assembly: Xunit.v3.Parallelization(Mode = Xunit.Sdk.ParallelMode.None)]

namespace CommandLine.PostgreSQL;

// ReSharper disable once UnusedType.Global
public class Startup : Common.Startup<PostgreSqlTestContainerDatabase, PostgreSqlExternalDatabase, PostgreSqlGrateTestContext>
{
    protected override DatabaseType DatabaseType => DatabaseType.PostgreSQL;
}
