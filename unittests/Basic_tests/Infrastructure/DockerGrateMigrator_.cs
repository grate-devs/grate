using Docker.Common.TestInfrastructure;
using DotNet.Testcontainers.Networks;
using grate.Configuration;
using grate.Migration;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Hosting;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Logging.Abstractions;
using NSubstitute;
using TestCommon.TestInfrastructure;

namespace Basic_tests.Infrastructure;

public sealed class DockerGrateMigrator_
{
    [Theory]
    [InlineData(null, null, "gratedevs/grate")]
    [InlineData(null, "grate-local:tests", "grate-local:tests")]
    [InlineData("custom:tests", null, "custom:tests")]
    [InlineData("custom:tests", "grate-local:tests", "custom:tests")]
    public async Task Application_image_configuration_does_not_replace_the_database_image(
        string? applicationImage, string? defaultImage, string expectedImage)
    {
        var configuration = new ConfigurationBuilder()
            .AddInMemoryCollection(new Dictionary<string, string?>
            {
                ["GrateTestConfig:DockerImage"] = "database-image:tests",
                ["GrateTestConfig:ApplicationDockerImage"] = applicationImage,
                ["GrateTestConfig:DefaultApplicationDockerImage"] = defaultImage
            })
            .Build();
        var testConfig = new GrateTestConfig();
        configuration.GetSection("GrateTestConfig").Bind(testConfig);

        var services = new ServiceCollection();
        services.AddSingleton(testConfig);
        services.AddSingleton(Substitute.For<INetwork>());
        services.AddSingleton<ILogger<DockerGrateMigrator>>(NullLogger<DockerGrateMigrator>.Instance);
        new TestStartup().RegisterMigrator(services);
        await using var provider = services.BuildServiceProvider();

        var migrator = Assert.IsType<DockerGrateMigrator>(provider.GetRequiredService<IGrateMigrator>());

        Assert.Equal(expectedImage, migrator.DockerImage);
        Assert.Equal("database-image:tests", testConfig.DockerImage);
    }

    private sealed class TestStartup : Docker.Common.Startup<ITestDatabase, ITestDatabase, IGrateTestContext>
    {
        protected override DatabaseType DatabaseType => DatabaseType.SQLite;

        internal void RegisterMigrator(IServiceCollection services) =>
            ConfigureExtraServices(services, new HostBuilderContext(new Dictionary<object, object>()));
    }
}
