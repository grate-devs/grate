using DotNet.Testcontainers.Containers;
using DotNet.Testcontainers.Networks;

namespace TestCommon.TestInfrastructure;
public abstract record TestContainerDatabase : ITestDatabase, IAsyncLifetime
{
    public abstract string DockerImage { get; }

    private readonly Random _random = Random.Shared;

    protected string AdminPassword { get; }
    
    protected abstract int InternalPort { get; }
    
    public ITestDatabase External => this with { IsInternal = false };
    private bool IsInternal { get; init; }
    
    public abstract INetwork Network { get; init; }
    protected abstract string NetworkAlias { get; }
    
    protected string Hostname => IsInternal ? NetworkAlias : TestContainer.Hostname;
    protected int Port => IsInternal ? InternalPort : TestContainer.GetMappedPublicPort(InternalPort);
    

    private const string LowerCase = "abcdefghijklmnopqrstuvwxyz";
    private const string UpperCase = "ABCDEFGHIJKLMNOPQRSTUVWXYZ";
    private const string Digits = "1234567890";
    
    protected TestContainerDatabase(GrateTestConfig grateTestConfig)
    {
        AdminPassword = _random.GetString(10, UpperCase) +
                        _random.GetString(10, LowerCase) +
                        _random.GetString(10, Digits);

        IsInternal = grateTestConfig.ConnectToDockerInternal;

        // ReSharper disable once VirtualMemberCallInConstructor
        TestContainer = InitializeTestContainer();
    }

    public IContainer TestContainer { get; }
    public abstract string AdminConnectionString { get; }

    public virtual async ValueTask InitializeAsync()
    {
        await Network.CreateAsync();
        await TestContainer.StartAsync();
    }

    public virtual async ValueTask DisposeAsync()
    {
        //await Network.DeleteAsync();
        await Network.DisposeAsync();
        await TestContainer.DisposeAsync();
    }

    protected abstract IContainer InitializeTestContainer();
    public abstract string ConnectionString(string database);
    public abstract string UserConnectionString(string database);
}
