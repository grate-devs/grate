using grate.Configuration;
using SqlServerCaseSensitive.TestInfrastructure;

[assembly: Xunit.v3.Parallelization(Mode = Xunit.Sdk.ParallelMode.None)]

namespace CommandLine.SqlServerCaseSensitive;

// ReSharper disable once UnusedType.Global
public class Startup : Common.Startup<SqlServerTestContainerDatabase, SqlServerExternalDatabase, SqlServerCaseSensitiveGrateTestContext>
{
    protected override DatabaseType DatabaseType => DatabaseType.SQLServer;
}
