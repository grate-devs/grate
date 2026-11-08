using Oracle.ManagedDataAccess.Client;
using TestCommon.TestInfrastructure;

namespace Oraclde.TestInfrastructure;

public class OracleExternalDatabase(GrateTestConfig grateTestConfig) : ITestDatabase
{
    public string AdminConnectionString { get; } = grateTestConfig.AdminConnectionString ?? throw new ArgumentNullException(nameof(grateTestConfig));

    public string ConnectionString(string database)
    {
        var builder = new OracleConnectionStringBuilder(AdminConnectionString)
        {
            UserID = database.ToUpper(),
            ConnectionTimeout = 3
        };
        return builder.ConnectionString;
    }

    public string UserConnectionString(string database)
    {
        var builder = new OracleConnectionStringBuilder(AdminConnectionString)
        {
            UserID = database.ToUpper(),
            ConnectionTimeout = 3
        };
        return builder.ConnectionString;
    }

}
