namespace TestCommon.TestInfrastructure;

public class TestDatabaseFixture(ITestDatabase testDatabase) : IAsyncLifetime
{
    public ITestDatabase TestDatabase { get; } = testDatabase;

    public async ValueTask InitializeAsync()
    {
        if (TestDatabase is IAsyncLifetime asyncLifetime)
        {
            await asyncLifetime.InitializeAsync();
        }
    }

    public async ValueTask DisposeAsync()
    {
        if (TestDatabase is IAsyncLifetime asyncLifetime)
        {
            await asyncLifetime.DisposeAsync();
        }
    }
}
