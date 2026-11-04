using grate.Configuration;
using SqlServer.TestInfrastructure;

[assembly: Xunit.v3.Parallelization(Mode = Xunit.Sdk.ParallelMode.None)]

namespace Docker.SqlServer;

// ReSharper disable once UnusedType.Global
public class Startup: Docker.Common.Startup<SqlServerTestContainerDatabase, SqlServerExternalDatabase, SqlServerGrateTestContext>
{
    protected override DatabaseType DatabaseType => DatabaseType.SQLServer;
}
