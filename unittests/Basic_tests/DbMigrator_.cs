using grate.Configuration;
using grate.Infrastructure;
using grate.Migration;
using Microsoft.Extensions.Logging;
using NSubstitute;

namespace Basic_tests;

// ReSharper disable once InconsistentNaming
public class DbMigrator_
{
    private readonly IDatabase _database = Substitute.For<IDatabase>();
    private readonly GrateConfiguration? _config = new();

    [Fact]
    public void Setting_the_config_does_not_change_the_original()
    {
        var config = new GrateConfiguration() { ConnectionString = "Server=server1" };
        var migrator = new DbMigrator(_database, null!, null!, config);

        var changedConfig = config with { ConnectionString = "Server=server2" };
        var changedMigrator = migrator with { Configuration = changedConfig };
        
        Assert.Equal("Server=server1", migrator.Configuration.ConnectionString);
        Assert.Equal("Server=server2", changedMigrator.Configuration.ConnectionString);
    }
    
    [Fact]
    public void Setting_the_Database_does_not_change_the_original()
    {
        _database.DatabaseName.Returns("server1");
        
        var migrator = new DbMigrator(_database, null!, null!, _config);

        var changedDatabase = Substitute.For<IDatabase>();
        changedDatabase.DatabaseName.Returns("server2");
        var changedMigrator = migrator with { Database = changedDatabase };
        
        Assert.Equal("server1", migrator.Database.DatabaseName);
        Assert.Equal("server2", changedMigrator.Database.DatabaseName);
    }
    
}
