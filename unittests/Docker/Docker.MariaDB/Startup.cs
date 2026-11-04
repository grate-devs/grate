using grate.Configuration;
using MariaDB.TestInfrastructure;

[assembly: Xunit.v3.Parallelization(Mode = Xunit.Sdk.ParallelMode.None)]

namespace Docker.MariaDB;

// ReSharper disable once UnusedType.Global
public class Startup: Docker.Common.Startup<MariaDbTestContainerDatabase, MariaDBExternalDatabase, MariaDbGrateTestContext>
{
    protected override DatabaseType DatabaseType => DatabaseType.MariaDB;
}
