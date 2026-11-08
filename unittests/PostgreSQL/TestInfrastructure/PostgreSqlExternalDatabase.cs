using Npgsql;
using TestCommon.TestInfrastructure;

namespace PostgreSQL.TestInfrastructure;

// ReSharper disable once ClassNeverInstantiated.Global
public class PostgreSqlExternalDatabase(GrateTestConfig grateTestConfig) : ITestDatabase
{
    public string AdminConnectionString { get; } = grateTestConfig.AdminConnectionString ?? throw new ArgumentNullException(nameof(grateTestConfig));

    public string ConnectionString(string database)
    {
        var builder = new NpgsqlConnectionStringBuilder(AdminConnectionString)
        {
            Database = database,
            Timeout = 5
        };
        return builder.ConnectionString;
    }

    public string UserConnectionString(string database)
    {
        var builder = new NpgsqlConnectionStringBuilder(AdminConnectionString)
        {
            Database = database,
            Username = "zorro" + database.ToLower()[..4],
            Password = "batmanZZ4",
            Timeout = 3
        };
        return builder.ConnectionString;
    }

}
