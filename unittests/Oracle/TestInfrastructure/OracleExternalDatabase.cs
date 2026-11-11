using Oracle.ManagedDataAccess.Client;
using TestCommon.TestInfrastructure;
using Oracle.TestInfrastructure;

namespace Oraclde.TestInfrastructure;

public class OracleExternalDatabase(GrateTestConfig grateTestConfig) : ITestDatabase
{
    private readonly string _adminConnectionString = grateTestConfig.AdminConnectionString ?? throw new ArgumentNullException(nameof(grateTestConfig));

    public string AdminConnectionString => OracleTestConnectionPools.Configure(_adminConnectionString);

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
