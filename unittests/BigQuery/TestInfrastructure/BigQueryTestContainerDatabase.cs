using DotNet.Testcontainers.Builders;
using DotNet.Testcontainers.Containers;
using DotNet.Testcontainers.Networks;
using grate.BigQuery.Infrastructure;
using Microsoft.Extensions.Logging;
using TestCommon.TestInfrastructure;

namespace BigQuery.TestInfrastructure;

/// <summary>
/// The BigQuery emulator (https://github.com/goccy/bigquery-emulator) in a container. It serves BigQuery's REST API
/// without credentials, for one project.
/// </summary>
// ReSharper disable once ClassNeverInstantiated.Global
public record BigQueryTestContainerDatabase(
    GrateTestConfig GrateTestConfig,
    ILogger<BigQueryTestContainerDatabase> Logger,
    INetwork Network
    )
    : TestContainerDatabase(GrateTestConfig)
{
    public const string ProjectId = "grate-test";

    public override string DockerImage => GrateTestConfig.DockerImage ?? "ghcr.io/goccy/bigquery-emulator:0.8.1";
    protected override int InternalPort => 9050;
    protected override string NetworkAlias => "bigquery-test-container";

    protected override IContainer InitializeTestContainer()
    {
        return new ContainerBuilder(DockerImage)
            .WithCommand($"--project={ProjectId}")
            .WithPortBinding(InternalPort, true)
            .WithNetworkAliases(NetworkAlias)
            .WithNetwork(Network)
            .WithWaitStrategy(Wait.ForUnixContainer().UntilHttpRequestIsSucceeded(
                request => request
                    .ForPort((ushort)InternalPort)
                    .ForPath($"/bigquery/v2/projects/{ProjectId}/datasets"),
                wait => wait.WithTimeout(TimeSpan.FromMinutes(1))))
            .WithLogger(Logger)
            .Build();
    }

    /// <summary>
    /// How many tests one emulator serves. The emulator reads every job it has kept on each request, so it slows down,
    /// and each DROP TABLE costs it memory that it does not give back, until it fails - so every few tests get a fresh
    /// one. The state is shared with the copy that <see cref="TestContainerDatabase.External"/> makes.
    /// </summary>
    private const int TestsPerEmulator = 3;

    private const int RestartAttempts = 3;

    private readonly EmulatorUse _use = new();

    private BigQueryConnectionSettings Settings => new(ProjectId, null, null, $"http://{Hostname}:{Port}");

    public override string AdminConnectionString
    {
        get
        {
            RestartForNewTest();
            return Settings.ToString();
        }
    }

    public override string ConnectionString(string database)
    {
        RestartForNewTest();
        return Settings.WithDataset(database).ToString();
    }

    public override string UserConnectionString(string database) => ConnectionString(database);

    private void RestartForNewTest()
    {
        var test = TestContext.Current.Test?.UniqueID;
        lock (_use)
        {
            if (test is null || test == _use.CurrentTest)
            {
                return;
            }

            _use.CurrentTest = test;
            _use.TestsServed++;
            if (_use.TestsServed <= TestsPerEmulator)
            {
                return;
            }

            _use.TestsServed = 1;
            for (var attempt = 1; ; attempt++)
            {
                TestContainer.StopAsync().GetAwaiter().GetResult();
                try
                {
                    TestContainer.StartAsync().GetAwaiter().GetResult();
                    return;
                }
                catch (TimeoutException) when (attempt < RestartAttempts)
                {
                    // Docker Desktop now and then does not forward the new host port after a restart
                }
            }
        }
    }

    private sealed class EmulatorUse
    {
        public string? CurrentTest { get; set; }
        public int TestsServed { get; set; }
    }
}
