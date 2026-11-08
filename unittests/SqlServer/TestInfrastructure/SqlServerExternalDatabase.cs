using Microsoft.Data.SqlClient;
using TestCommon.TestInfrastructure;

namespace SqlServer.TestInfrastructure;

public class SqlServerExternalDatabase(GrateTestConfig grateTestConfig) : ITestDatabase
{
    public string AdminConnectionString { get; } = grateTestConfig.AdminConnectionString ?? throw new ArgumentNullException(nameof(grateTestConfig));

    public string ConnectionString(string database)
    {
        var builder = new SqlConnectionStringBuilder(AdminConnectionString)
        {
            InitialCatalog = database,
            ConnectTimeout = 3
        };
        return builder.ConnectionString;
    }

    public string UserConnectionString(string database)
    {
        var builder = new SqlConnectionStringBuilder(AdminConnectionString)
        {
            InitialCatalog = database,
            UserID = "zorro",
            Password = "batmanZZ4",
            ConnectTimeout = 3
        };
        return builder.ConnectionString;
    }

}
