using Microsoft.Data.SqlClient;
using TestCommon.TestInfrastructure;

namespace SqlServerCaseSensitive.TestInfrastructure;

public class SqlServerExternalDatabase(string adminConnectionString) : ITestDatabase
{
    public string AdminConnectionString { get; } = adminConnectionString;

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
