using System.Diagnostics.CodeAnalysis;
using DotNet.Testcontainers.Builders;
using grate.Infrastructure;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.DependencyInjection.Extensions;
using Microsoft.Extensions.Hosting;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Logging.Console;
using TestCommon.TestInfrastructure;

namespace TestCommon;

// ReSharper disable once UnusedType.Global
public abstract class Startup
{
    public void ConfigureHost(IHostBuilder hostBuilder) =>
        hostBuilder
            .ConfigureHostConfiguration(builder => builder.AddEnvironmentVariables())
            .ConfigureAppConfiguration((context, builder) => { });

    // ReSharper disable once UnusedMember.Global
    public void ConfigureServices(IServiceCollection services, HostBuilderContext context)
    {
        services.AddLogging(
                lb => lb
                    .AddXUnit()
                    .AddConsole(options =>
                    {
                        options.FormatterName = GrateConsoleFormatter.FormatterName;
                        options.LogToStandardErrorThreshold = LogLevel.Critical;
                    })
                    .AddFilter("Grate.Migration.Internal", LogLevel.Critical)
                    .AddConsoleFormatter<GrateConsoleFormatter, SimpleConsoleFormatterOptions>()
                    .SetMinimumLevel(TestConfig.GetLogLevel())
            );

        // SQLite and isolated provider tests do not need Docker.
        services.AddSingleton(_ => new NetworkBuilder()
            .WithName(Guid.NewGuid().ToString("D"))
            .Build());

        ConfigureExtraServices(services, context);

        services.TryAddSingleton(TestContextType);
        RegisterTestDatabase(services, context.Configuration);
    }

    [DynamicallyAccessedMembers(DynamicallyAccessedMemberTypes.PublicConstructors)]
    protected abstract Type TestContainerDatabaseType { get; }

    [DynamicallyAccessedMembers(DynamicallyAccessedMemberTypes.PublicConstructors)]
    protected abstract Type ExternalTestDatabaseType { get; }

    [DynamicallyAccessedMembers(DynamicallyAccessedMemberTypes.PublicConstructors)]
    protected abstract Type TestContextType { get; }

    // ReSharper disable once UnassignedGetOnlyAutoProperty
    protected virtual GrateTestConfig ExtraConfiguration(GrateTestConfig config) => config;

    protected void RegisterTestDatabase(IServiceCollection services, IConfiguration configuration)
    {
        var testConfig = new GrateTestConfig();
        configuration.Bind("GrateTestConfig", testConfig);
        testConfig = ExtraConfiguration(testConfig);
        services.TryAddSingleton(testConfig);

        if (testConfig.AdminConnectionString != null)
        {
            services.TryAddSingleton(typeof(ITestDatabase), ExternalTestDatabaseType);
        }
        else
        {
            services.TryAddSingleton(typeof(ITestDatabase), TestContainerDatabaseType);
        }
    }

    protected virtual void ConfigureExtraServices(IServiceCollection services, HostBuilderContext context) { }

}
