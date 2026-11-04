using DotNet.Testcontainers.Configurations;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Hosting;
using NSubstitute;
using NSubstitute.ReturnsExtensions;
using TestCommon.TestInfrastructure;

namespace Basic_tests.Infrastructure;

[Collection(nameof(TestStartupTests))]
public sealed class TestStartupTests
{
    [Fact]
    public async Task Non_container_services_can_be_resolved_without_initializing_Docker()
    {
        var operatingSystem = TestcontainersSettings.OS;
        try
        {
            // A null Docker endpoint simulates a runner without Docker.
            var unavailableDocker = Substitute.For<IOperatingSystem>();
            unavailableDocker.DockerEndpointAuthConfig.ReturnsNull();
            TestcontainersSettings.OS = unavailableDocker;
            var services = new ServiceCollection();
            var context = new HostBuilderContext(new Dictionary<object, object>())
            {
                Configuration = new ConfigurationBuilder().Build()
            };
            new TestStartup().ConfigureServices(services, context);
            await using var provider = services.BuildServiceProvider();

            Assert.NotNull(provider.GetRequiredService<IndependentService>());
            Assert.IsType<TestDatabase>(provider.GetRequiredService<ITestDatabase>());
        }
        finally
        {
            TestcontainersSettings.OS = operatingSystem;
        }
    }

    [CollectionDefinition(nameof(TestStartupTests), DisableParallelization = true)]
    public sealed class TestcontainersConfigurationCollection;

    private sealed class TestStartup : TestCommon.Startup
    {
        protected override Type TestContainerDatabaseType => typeof(TestDatabase);
        protected override Type ExternalTestDatabaseType => typeof(TestDatabase);
        protected override Type TestContextType => typeof(IndependentService);
    }

    public sealed class IndependentService;

    public sealed class TestDatabase : ITestDatabase
    {
        public string AdminConnectionString => "unused";
        public string ConnectionString(string database) => "unused";
        public string UserConnectionString(string database) => "unused";
    }
}
