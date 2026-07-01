using grate.Configuration;
using grate.Infrastructure;
using grate.Migration;

namespace SqlServerCaseSensitive.Basic_tests;

public class TokenReplacerTests(IDatabase database)
{
    [Fact]
    public void EnsureDbMakesItToTokens()
    {
        var config = new GrateConfiguration()
        {
            ConnectionString = "Server=(LocalDb)\\mssqllocaldb;Database=TestDb;",
            Folders = Folders.Default
        };


        database.InitializeConnections(config);

        var provider = new TokenProvider(config, database);
        var tokens = provider.GetTokens();

        Assert.Equal("TestDb", tokens["DatabaseName"]);
        Assert.Equal("(LocalDb)\\mssqllocaldb", tokens["ServerName"]);
    }
}
