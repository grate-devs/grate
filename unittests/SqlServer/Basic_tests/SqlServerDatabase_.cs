using grate.Configuration;
using Microsoft.Data.SqlClient;
using SqlServer.TestInfrastructure;

namespace SqlServer.Basic_tests;

// ReSharper disable once InconsistentNaming
public class SqlServerDatabase_(InspectableSqlServerDatabase sqlServerDatabase)
{
    // [Fact(Skip = "This is turned off now, as disabling pooling explicitly by default was causing performance issues")]
    // Please see the test Real_world_issues.cs#Bug232_Timeout_v1U002E4U002E0_Regression for more information, and how 
    // to work around this issue, setting the transaction handling for the RunAfterCreateDatabase folder to autonomous.
    // public async Task Disables_pooling_if_not_explicitly_set_in_connection_string()
    // {
    //     var connStr = "Server=dummy";
    //     var cfg = new GrateConfiguration() { ConnectionString = connStr };
    //     await sqlServerDatabase.InitializeConnections(cfg);
    //
    //     var conn = sqlServerDatabase.GetConnection();
    //     var builder = new SqlConnectionStringBuilder(conn.ConnectionString);
    //     builder.Pooling.Should().BeFalse();
    // }

    [Fact]
    public async Task Leaves_pooling_as_configured_if_set_explicitly_in_connection_string()
    {
        var connStr = "Server=dummy;Pooling=true";
        var cfg = new GrateConfiguration() { ConnectionString = connStr };
        await sqlServerDatabase.InitializeConnections(cfg);

        var conn = sqlServerDatabase.GetConnection();
        var builder = new SqlConnectionStringBuilder(conn.ConnectionString);
        Assert.True(builder.Pooling);
    }
}
