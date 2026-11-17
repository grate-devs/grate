using Aspire.Hosting;
using Aspire.Hosting.ApplicationModel;
using Grate.Aspire.Hosting;
using Xunit;

namespace AspireMariaDb.Tests;

public sealed class MariaDbGrateMigrationTests : IDisposable
{
    private readonly string _directory = Directory.CreateTempSubdirectory("grate-aspire-mariadb-").FullName;

    [Fact]
    public async Task MariaDb_image_override_preserves_native_password_endpoint_and_data_volume()
    {
        var builder = CreateBuilder();
        var password = builder.AddParameter("password", secret: true);
        var server = builder.AddMySql("mariadb", password: password)
            .WithImage("mariadb", "12.3.3")
            .WithDataVolume("example-mariadb-data");
        var original = server.Resource.Annotations.ToArray();
        IResourceBuilder<MySqlDatabaseResource> database = server.AddDatabase("appdb");

        IResourceBuilder<GrateMigrationResource> migration = database.AddGrateMigration();

        var environment = await GetEnvironment(builder, server.Resource);
        Assert.Same(password.Resource, environment["MYSQL_ROOT_PASSWORD"]);
        Assert.Single(environment);
        var image = Assert.Single(server.Resource.Annotations.OfType<ContainerImageAnnotation>());
        Assert.Equal("mariadb", image.Image);
        Assert.Equal("12.3.3", image.Tag);
        Assert.Equal("docker.io", image.Registry);
        var endpoint = Assert.Single(server.Resource.Annotations.OfType<EndpointAnnotation>());
        Assert.Equal(3306, endpoint.TargetPort);
        var mount = Assert.Single(server.Resource.Annotations.OfType<ContainerMountAnnotation>());
        Assert.Equal("example-mariadb-data", mount.Source);
        Assert.Equal("/var/lib/mysql", mount.Target);
        Assert.Equal(original, server.Resource.Annotations);
        Assert.Contains(migration.Resource.Annotations.OfType<WaitAnnotation>(), wait => wait.Resource == server.Resource);
    }

    [Fact]
    public async Task Native_database_keeps_deferred_credentials_and_waits_for_database_and_server_readiness()
    {
        var builder = CreateBuilder();
        var server = builder.AddMySql("mariadb").WithImage("mariadb", "12.3.3");
        var database = server.AddDatabase("appdb", "application_data");
        var original = database.Resource.Annotations.ToArray();

        var migration = database.AddGrateMigration().WithScriptsFolder(_directory);
        var environment = await GetEnvironment(builder, migration.Resource);

        Assert.Equal("appdb-grate", migration.Resource.Name);
        Assert.Equal("mariadb", environment["DATABASE_TYPE"]);
        Assert.Equal("false", environment["CREATE_DATABASE"]);
        Assert.Equal("LOCAL", environment["ENVIRONMENT"]);
        var connection = Assert.IsType<ReferenceExpression>(environment["APP_CONNSTRING"]);
        Assert.Equal(database.Resource.ConnectionStringExpression.ValueExpression, connection.ValueExpression);
        Assert.Contains("application_data", connection.ValueExpression);
        Assert.NotEmpty(connection.ValueProviders);
        Assert.NotEmpty(server.Resource.ConnectionStringExpression.ValueProviders);
        Assert.Equal(original, database.Resource.Annotations);
        Assert.Contains(database.Resource.Annotations, annotation => annotation is HealthCheckAnnotation);
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
    public async Task Native_creation_script_and_migration_overrides_remain_consumer_controlled()
    {
        var builder = CreateBuilder();
        var database = builder.AddMySql("mariadb").WithImage("mariadb", "12.3.3").AddDatabase("appdb")
            .WithCreationScript("CREATE DATABASE IF NOT EXISTS appdb CHARACTER SET utf8mb4;");
        var original = database.Resource.Annotations.ToArray();
        var connection = ReferenceExpression.Create($"Server=custom;Database=appdb;User ID=app");
        var migration = database.AddGrateMigration("custom-migration", waitForDatabase: false)
            .WithScriptsFolder(_directory, "/custom sql")
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
        Assert.Equal("mariadb", environment["DATABASE_TYPE"]);
        Assert.Equal(original, database.Resource.Annotations);
        Assert.Equal("/custom sql", Assert.Single(migration.Resource.Annotations.OfType<ContainerMountAnnotation>()).Target);
        var image = Assert.Single(migration.Resource.Annotations.OfType<ContainerImageAnnotation>());
        Assert.Equal("example/grate", image.Image);
        Assert.Equal("custom", image.Tag);
    }

    [Fact]
    public void Consumers_only_wait_when_explicitly_configured()
    {
        var builder = CreateBuilder();
        var database = builder.AddMySql("mariadb").WithImage("mariadb", "12.3.3").AddDatabase("appdb");
        var consumer = builder.AddContainer("consumer", "example/api").WithReference(database);
        var original = consumer.Resource.Annotations.ToArray();
        var migration = database.AddGrateMigration().WithScriptsFolder(_directory);
        Assert.Equal(original, consumer.Resource.Annotations);
        Assert.Empty(consumer.Resource.Annotations.OfType<WaitAnnotation>());

        consumer.WaitForCompletion(migration);

        var wait = Assert.Single(consumer.Resource.Annotations.OfType<WaitAnnotation>());
        Assert.Equal(WaitType.WaitForCompletion, wait.WaitType);
        Assert.Equal(0, wait.ExitCode);
        Assert.Same(migration.Resource, wait.Resource);
    }

    [Fact]
    public void Duplicate_migration_names_are_rejected()
    {
        var builder = CreateBuilder();
        var database = builder.AddMySql("mariadb").WithImage("mariadb", "12.3.3").AddDatabase("appdb");
        database.AddGrateMigration();

        Assert.Throws<DistributedApplicationException>(() => database.AddGrateMigration());
        Assert.Single(builder.Resources.OfType<GrateMigrationResource>());
    }

    [Fact]
    public void Null_database_is_rejected() =>
        Assert.Throws<ArgumentNullException>(() => MySqlGrateMigrationExtensions.AddGrateMigration(null!));

    [Fact]
    public void Missing_scripts_directory_is_rejected()
    {
        var builder = CreateBuilder();
        var database = builder.AddMySql("mariadb").WithImage("mariadb", "12.3.3").AddDatabase("appdb");
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
