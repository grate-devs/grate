using SqlServerCaseSensitive.TestInfrastructure;
using TestCommon.TestInfrastructure;

namespace CommandLine.SqlServerCaseSensitive.TestInfrastructure;

public sealed class CaseSensitiveSqlServerExternalDatabase(GrateTestConfig configuration)
    : SqlServerExternalDatabase(configuration.AdminConnectionString
        ?? throw new ArgumentException("An admin connection string is required.", nameof(configuration)))
{
}
