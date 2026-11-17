using Aspire.Hosting;
using Aspire.Hosting.ApplicationModel;
using Grate.Aspire.Hosting;
using Xunit;

namespace AspireOracle.Tests;

public sealed class OracleGrateMigrationTests : IDisposable
{
    private readonly string _directory = Directory.CreateTempSubdirectory("grate-aspire-oracle-").FullName;

    [Fact]
    public async Task Native_database_preserves_deferred_service_credentials_and_waits_for_parent_readiness()
    {
        var builder = CreateBuilder();
        var server = builder.AddOracle("oracle");
        var database = server.AddDatabase("appdb", "FREEPDB1");
        var original = database.Resource.Annotations.ToArray();

        var migration = database.AddGrateMigration().WithScriptsFolder(_directory);
        var environment = await GetEnvironment(builder, migration.Resource);

        Assert.Equal("appdb-grate", migration.Resource.Name);
        Assert.Equal("oracle", environment["DATABASE_TYPE"]);
        Assert.Equal("false", environment["CREATE_DATABASE"]);
        Assert.Equal("LOCAL", environment["ENVIRONMENT"]);
        var connection = Assert.IsType<ReferenceExpression>(environment["APP_CONNSTRING"]);
        Assert.Equal(database.Resource.ConnectionStringExpression.ValueExpression, connection.ValueExpression);
        Assert.Contains("FREEPDB1", connection.ValueExpression);
        Assert.Equal("FREEPDB1", server.Resource.Databases["appdb"]);
        Assert.Contains("user id=system", server.Resource.ConnectionStringExpression.ValueExpression);
        Assert.NotEmpty(server.Resource.ConnectionStringExpression.ValueProviders);
        Assert.Equal(original, database.Resource.Annotations);
        var waits = migration.Resource.Annotations.OfType<WaitAnnotation>().ToArray();
        Assert.Equal(2, waits.Length);
        Assert.Contains(waits, wait => wait.Resource == database.Resource);
        Assert.Contains(waits, wait => wait.Resource == server.Resource);
        Assert.All(waits, wait => Assert.Equal(WaitType.WaitUntilHealthy, wait.WaitType));
        var image = Assert.Single(migration.Resource.Annotations.OfType<ContainerImageAnnotation>());
        Assert.Equal("gratedevs/grate", image.Image);
        Assert.Equal("2.3.0", image.Tag);
    }

    [Fact]
    public async Task Native_builder_overrides_name_image_connection_and_environment_without_waits()
    {
        var builder = CreateBuilder();
        var database = builder.AddOracle("oracle").AddDatabase("appdb", "existing_service");
        var connection = ReferenceExpression.Create($"User Id=app;Data Source=custom/service");
        var migration = database.AddGrateMigration("custom-migration", waitForDatabase: false)
            .WithScriptsFolder(_directory)
            .WithEnvironment("APP_CONNSTRING", connection)
            .WithEnvironment("CREATE_DATABASE", "true")
            .WithEnvironment("ENVIRONMENT", "TEST")
            .WithImage("example/grate", "custom");

        var environment = await GetEnvironment(builder, migration.Resource);

        Assert.Equal("custom-migration", migration.Resource.Name);
        Assert.Empty(migration.Resource.Annotations.OfType<WaitAnnotation>());
        Assert.Same(connection, environment["APP_CONNSTRING"]);
        Assert.Equal("true", environment["CREATE_DATABASE"]);
        Assert.Equal("TEST", environment["ENVIRONMENT"]);
        Assert.Equal("oracle", environment["DATABASE_TYPE"]);
        Assert.Equal("example/grate", Assert.Single(migration.Resource.Annotations.OfType<ContainerImageAnnotation>()).Image);
    }

    [Fact]
    public void Consumers_only_wait_when_explicitly_configured()
    {
        var builder = CreateBuilder();
        var database = builder.AddOracle("oracle").AddDatabase("appdb", "FREEPDB1");
        var consumer = builder.AddContainer("consumer", "example/api");
        var migration = database.AddGrateMigration().WithScriptsFolder(_directory);
        Assert.Empty(consumer.Resource.Annotations.OfType<WaitAnnotation>());

        consumer.WaitForCompletion(migration);

        var wait = Assert.Single(consumer.Resource.Annotations.OfType<WaitAnnotation>());
        Assert.Equal(WaitType.WaitForCompletion, wait.WaitType);
        Assert.Equal(0, wait.ExitCode);
    }

    [Fact]
    public void Duplicate_migration_names_are_rejected()
    {
        var builder = CreateBuilder();
        var database = builder.AddOracle("oracle").AddDatabase("appdb", "FREEPDB1");
        database.AddGrateMigration();

        Assert.Throws<DistributedApplicationException>(() => database.AddGrateMigration());
        Assert.Single(builder.Resources.OfType<GrateMigrationResource>());
    }

    [Fact]
    public void Null_database_is_rejected() =>
        Assert.Throws<ArgumentNullException>(() => OracleGrateMigrationExtensions.AddGrateMigration(null!));

    [Fact]
    public void Missing_scripts_directory_is_rejected()
    {
        var builder = CreateBuilder();
        var database = builder.AddOracle("oracle").AddDatabase("appdb", "FREEPDB1");
        var migration = database.AddGrateMigration();

        Assert.Throws<DirectoryNotFoundException>(() => migration.WithScriptsFolder(Path.Combine(_directory, "absent")));
        Assert.Empty(migration.Resource.Annotations.OfType<ContainerMountAnnotation>());
    }

    private IDistributedApplicationBuilder CreateBuilder() => DistributedApplication.CreateBuilder(
        new DistributedApplicationOptions { ProjectDirectory = _directory, Args = [], DisableDashboard = true });

    private static async Task<Dictionary<string, object>> GetEnvironment(IDistributedApplicationBuilder builder, IResource resource)
    {
        var environment = new Dictionary<string, object>();
        var context = new EnvironmentCallbackContext(builder.ExecutionContext, resource, environment, CancellationToken.None);
        foreach (var annotation in resource.Annotations.OfType<EnvironmentCallbackAnnotation>())
        {
            await annotation.Callback(context);
        }
        return environment;
    }

    public void Dispose() => Directory.Delete(_directory, recursive: true);
}
