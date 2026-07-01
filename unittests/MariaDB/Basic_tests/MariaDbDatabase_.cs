using grate.Configuration;
using MariaDB.TestInfrastructure;
using MySqlConnector;

namespace MariaDB.Basic_tests;

// ReSharper disable once InconsistentNaming
public class MariaDbDatabase_(InspectableMariaDbDatabase mariaDb)
{
    [Fact]
    public async Task Disables_pipelining_if_not_explicitly_set_in_connection_string()
    {
        var connStr = "Server=dummy";
        var cfg = new GrateConfiguration() { ConnectionString = connStr };
        await mariaDb.InitializeConnections(cfg);

        var conn = mariaDb.GetConnection();
        var builder = new MySqlConnectionStringBuilder(conn.ConnectionString);
        Assert.False(builder.Pipelining);
    }

    [Fact]
    public async Task Leaves_pipelining_as_configured_if_set_explicitly_in_connection_string()
    {
        var connStr = "Server=dummy;Pipelining=true";
        var cfg = new GrateConfiguration() { ConnectionString = connStr };
        await mariaDb.InitializeConnections(cfg);

        var conn = mariaDb.GetConnection();
        var builder = new MySqlConnectionStringBuilder(conn.ConnectionString);
        Assert.True(builder.Pipelining);
    }

}
