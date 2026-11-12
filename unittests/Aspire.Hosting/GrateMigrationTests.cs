using System.Diagnostics;
using Aspire.Hosting;
using Aspire.Hosting.ApplicationModel;
using Grate.Aspire.Hosting;
using Xunit;

namespace AspireHosting.Tests;

public sealed class GrateMigrationTests : IDisposable
{
    private readonly string _appHostDirectory = Directory.CreateTempSubdirectory("grate-aspire-").FullName;

    [Fact]
    public async Task Database_context_supplies_migration_defaults_without_rendering_secrets()
    {
        var builder = CreateBuilder();
        var database = builder.AddPostgres("postgres").AddDatabase("appdb");
        var databaseWaits = database.Resource.Annotations.OfType<WaitAnnotation>().ToArray();

        var migration = database.AddGrateMigration().WithScriptsFolder(CreateScripts());
        var environment = await GetEnvironment(builder, migration.Resource);

        Assert.Equal("appdb-grate", migration.Resource.Name);
        var image = Assert.Single(migration.Resource.Annotations.OfType<ContainerImageAnnotation>());
        Assert.Equal("gratedevs/grate", image.Image);
        Assert.Equal("2.3.0", image.Tag);
        Assert.IsType<ReferenceExpression>(environment["APP_CONNSTRING"]);
        Assert.Equal(database.Resource.ConnectionStringExpression.ValueExpression,
            ((ReferenceExpression)environment["APP_CONNSTRING"]).ValueExpression);
        Assert.Equal("postgresql", environment["DATABASE_TYPE"]);
        Assert.Equal("false", environment["CREATE_DATABASE"]);
        Assert.Equal("LOCAL", environment["ENVIRONMENT"]);
        var waits = migration.Resource.Annotations.OfType<WaitAnnotation>().ToArray();
        Assert.Equal(2, waits.Length);
        Assert.Contains(waits, wait => wait.Resource == database.Resource);
        Assert.Contains(waits, wait => wait.Resource == database.Resource.Parent);
        Assert.All(waits, wait => Assert.Equal(WaitType.WaitUntilHealthy, wait.WaitType));
        Assert.Equal(databaseWaits, database.Resource.Annotations.OfType<WaitAnnotation>());
        Assert.Single(builder.Resources.OfType<GrateMigrationResource>());
    }

    [Fact]
    public async Task Native_builder_customization_overrides_environment_image_and_name()
    {
        var builder = CreateBuilder();
        var database = builder.AddPostgres("postgres").AddDatabase("appdb");
        var connection = ReferenceExpression.Create($"Host=custom;Database=appdb");

        var migration = database.AddGrateMigration("custom-migration", waitForDatabase: false)
            .WithScriptsFolder(CreateScripts())
            .WithImage("custom/grate", "custom-tag")
            .WithImageRegistry("registry.example")
            .WithContainerName("explicit-container")
            .WithEnvironment("APP_CONNSTRING", connection)
            .WithEnvironment("DATABASE_TYPE", "sqlserver")
            .WithEnvironment("CREATE_DATABASE", "true")
            .WithEnvironment("ENVIRONMENT", "TEST")
            .WithEnvironment("VERSION", "42")
            .WithEnvironment("TRANSACTION", "true")
            .WithEnvironment("GRATE_OUTPUT_PATH", "/artifacts");
        var environment = await GetEnvironment(builder, migration.Resource);

        Assert.Equal("custom-migration", migration.Resource.Name);
        var image = Assert.Single(migration.Resource.Annotations.OfType<ContainerImageAnnotation>());
        Assert.Equal("custom/grate", image.Image);
        Assert.Equal("custom-tag", image.Tag);
        Assert.Equal("registry.example", image.Registry);
        Assert.Same(connection, environment["APP_CONNSTRING"]);
        Assert.Equal("sqlserver", environment["DATABASE_TYPE"]);
        Assert.Equal("true", environment["CREATE_DATABASE"]);
        Assert.Equal("TEST", environment["ENVIRONMENT"]);
        Assert.Equal("42", environment["VERSION"]);
        Assert.Equal("true", environment["TRANSACTION"]);
        Assert.Equal("/artifacts", environment["GRATE_OUTPUT_PATH"]);
        Assert.Empty(migration.Resource.Annotations.OfType<WaitAnnotation>());
    }

    [Fact]
    public async Task Scripts_are_relative_to_AppHost_and_replacement_preserves_unrelated_mounts()
    {
        var builder = CreateBuilder();
        var database = builder.AddPostgres("postgres").AddDatabase("appdb");
        CreateScripts("first scripts");
        var replacement = CreateScripts("second scripts");
        var migration = database.AddGrateMigration()
            .WithScriptsFolder("first scripts")
            .WithBindMount(_appHostDirectory, "/other", isReadOnly: true)
            .WithScriptsFolder("second scripts", "/custom scripts", isReadOnly: false);

        var mounts = migration.Resource.Annotations.OfType<ContainerMountAnnotation>().ToArray();
        Assert.Equal(2, mounts.Length);
        Assert.Contains(mounts, mount => mount.Target == "/other");
        var scriptsMount = Assert.Single(mounts, mount => mount.Target == "/custom scripts");
        Assert.Equal(replacement, scriptsMount.Source);
        Assert.False(scriptsMount.IsReadOnly);
        var arguments = await GetArguments(migration.Resource);
        Assert.Equal("/custom scripts", arguments[3]);
        Assert.DoesNotContain("/db", arguments);
    }

    [Fact]
    public void Default_scripts_mount_is_read_only_and_uses_db_target()
    {
        var builder = CreateBuilder();
        var database = builder.AddPostgres("postgres").AddDatabase("appdb");
        var scripts = CreateScripts();

        var migration = database.AddGrateMigration().WithScriptsFolder(scripts);

        var mount = Assert.Single(migration.Resource.Annotations.OfType<ContainerMountAnnotation>());
        Assert.Equal(scripts, mount.Source);
        Assert.Equal("/db", mount.Target);
        Assert.True(mount.IsReadOnly);
    }

    [Fact]
    public async Task Missing_scripts_configuration_prevents_argument_generation()
    {
        var builder = CreateBuilder();
        var database = builder.AddPostgres("postgres").AddDatabase("appdb");
        var migration = database.AddGrateMigration();

        var error = await Assert.ThrowsAsync<InvalidOperationException>(() => GetArguments(migration.Resource));

        Assert.Contains("WithScriptsFolder", error.Message);
    }

    [Fact]
    public void Missing_scripts_directory_is_rejected_without_adding_a_mount()
    {
        var builder = CreateBuilder();
        var database = builder.AddPostgres("postgres").AddDatabase("appdb");
        var migration = database.AddGrateMigration();

        Assert.Throws<DirectoryNotFoundException>(() => migration.WithScriptsFolder("absent"));
        Assert.Empty(migration.Resource.Annotations.OfType<ContainerMountAnnotation>());
    }

    [Theory]
    [InlineData("")]
    [InlineData("relative")]
    [InlineData("/")]
    public void Invalid_container_script_target_is_rejected(string target)
    {
        var builder = CreateBuilder();
        var database = builder.AddPostgres("postgres").AddDatabase("appdb");

        Assert.Throws<ArgumentException>(() => database.AddGrateMigration().WithScriptsFolder(CreateScripts(), target));
    }

    [Fact]
    public void Duplicate_names_are_rejected_instead_of_creating_ambiguous_migrations()
    {
        var builder = CreateBuilder();
        var database = builder.AddPostgres("postgres").AddDatabase("appdb");
        database.AddGrateMigration();

        Assert.Throws<DistributedApplicationException>(() => database.AddGrateMigration());
        Assert.Single(builder.Resources.OfType<GrateMigrationResource>());
    }

    [Fact]
    public void Consumer_waits_for_successful_completion_only_when_explicitly_configured()
    {
        var builder = CreateBuilder();
        var database = builder.AddPostgres("postgres").AddDatabase("appdb");
        var consumer = builder.AddContainer("consumer", "example/image");
        var migration = database.AddGrateMigration().WithScriptsFolder(CreateScripts());
        Assert.Empty(consumer.Resource.Annotations.OfType<WaitAnnotation>());

        consumer.WaitForCompletion(migration);

        var wait = Assert.Single(consumer.Resource.Annotations.OfType<WaitAnnotation>());
        Assert.Same(migration.Resource, wait.Resource);
        Assert.Equal(WaitType.WaitForCompletion, wait.WaitType);
        Assert.Equal(0, wait.ExitCode);
    }

    [Fact]
    public async Task Extra_arguments_follow_the_shell_sentinel_and_scripts_argument()
    {
        var builder = CreateBuilder();
        var database = builder.AddPostgres("postgres").AddDatabase("appdb");
        var migration = database.AddGrateMigration().WithScriptsFolder(CreateScripts())
            .WithArgs("--commandtimeout=7", "--schemaname=custom");

        var arguments = await GetArguments(migration.Resource);

        Assert.Equal("/bin/sh", migration.Resource.Entrypoint);
        Assert.Equal("-c", arguments[0]);
        Assert.Equal("grate", arguments[2]);
        Assert.Equal("/db", arguments[3]);
        Assert.Equal(new object[] { "--commandtimeout=7", "--schemaname=custom" }, arguments.Skip(4));
    }

    [Fact]
    public async Task SqlServer_uses_its_deferred_connection_and_waits_for_Aspire_database_provisioning()
    {
        var builder = CreateBuilder();
        var database = builder.AddSqlServer("sqlserver").AddDatabase("appdb");

        var migration = database.AddGrateMigration().WithScriptsFolder(CreateScripts());
        var environment = await GetEnvironment(builder, migration.Resource);

        Assert.Equal("appdb-grate", migration.Resource.Name);
        Assert.Equal("sqlserver", environment["DATABASE_TYPE"]);
        Assert.Equal("false", environment["CREATE_DATABASE"]);
        Assert.Equal(database.Resource.ConnectionStringExpression.ValueExpression,
            ((ReferenceExpression)environment["APP_CONNSTRING"]).ValueExpression);
        var waits = migration.Resource.Annotations.OfType<WaitAnnotation>().ToArray();
        Assert.Equal(2, waits.Length);
        Assert.Contains(waits, wait => wait.Resource == database.Resource);
        Assert.Contains(waits, wait => wait.Resource == database.Resource.Parent);
        Assert.All(waits, wait => Assert.Equal(WaitType.WaitUntilHealthy, wait.WaitType));
        Assert.Equal("2.3.0", Assert.Single(migration.Resource.Annotations.OfType<ContainerImageAnnotation>()).Tag);
    }

    [Fact]
    public async Task SqlServer_overrides_name_readiness_and_connection_with_standard_builder_methods()
    {
        var builder = CreateBuilder();
        var database = builder.AddSqlServer("sqlserver").AddDatabase("appdb");
        var connection = ReferenceExpression.Create($"Server=custom;Database=appdb");

        var migration = database.AddGrateMigration("sql-migration", waitForDatabase: false)
            .WithEnvironment("APP_CONNSTRING", connection)
            .WithScriptsFolder(CreateScripts());
        var environment = await GetEnvironment(builder, migration.Resource);

        Assert.Equal("sql-migration", migration.Resource.Name);
        Assert.Empty(migration.Resource.Annotations.OfType<WaitAnnotation>());
        Assert.Same(connection, environment["APP_CONNSTRING"]);
    }

    [Fact]
    public async Task Sqlite_shares_the_writable_directory_and_keeps_the_consumers_host_path()
    {
        var builder = CreateBuilder();
        var dataDirectory = Path.Combine(_appHostDirectory, "data files");
        var database = builder.AddSqlite("appdb", dataDirectory, "demo file.db");
        var hostExpression = database.Resource.ConnectionStringExpression.ValueExpression;

        var migration = database.AddGrateMigration().WithScriptsFolder(CreateScripts());
        var environment = await GetEnvironment(builder, migration.Resource);

        Assert.Equal("appdb-grate", migration.Resource.Name);
        Assert.Equal("sqlite", environment["DATABASE_TYPE"]);
        Assert.Equal("false", environment["CREATE_DATABASE"]);
        var connection = Assert.IsType<ReferenceExpression>(environment["APP_CONNSTRING"]).ValueExpression;
        Assert.Contains("/grate-data/demo file.db", connection);
        Assert.DoesNotContain(dataDirectory, connection);
        Assert.Equal(hostExpression, database.Resource.ConnectionStringExpression.ValueExpression);
        Assert.Contains(dataDirectory, hostExpression);
        Assert.Empty(migration.Resource.Annotations.OfType<WaitAnnotation>());
        var mount = Assert.Single(migration.Resource.Annotations.OfType<ContainerMountAnnotation>(), item => item.Target == "/grate-data");
        Assert.Equal(dataDirectory, mount.Source);
        Assert.False(mount.IsReadOnly);
        Assert.True(Directory.Exists(dataDirectory));
    }

    [Fact]
    public async Task Sqlite_supports_named_migrations_custom_data_targets_and_scripts_replacement()
    {
        var builder = CreateBuilder();
        var database = builder.AddSqlite("appdb", Path.Combine(_appHostDirectory, "data"), "demo.db");
        var migration = database.AddGrateMigration("sqlite-migration", containerDataPath: "/custom-data/")
            .WithScriptsFolder(CreateScripts())
            .WithScriptsFolder(CreateScripts("other scripts"), "/other-scripts");

        var environment = await GetEnvironment(builder, migration.Resource);

        Assert.Equal("sqlite-migration", migration.Resource.Name);
        Assert.Contains("/custom-data/demo.db", ((ReferenceExpression)environment["APP_CONNSTRING"]).ValueExpression);
        var mounts = migration.Resource.Annotations.OfType<ContainerMountAnnotation>().ToArray();
        Assert.Equal(2, mounts.Length);
        Assert.Contains(mounts, mount => mount.Target == "/custom-data" && !mount.IsReadOnly);
        Assert.Contains(mounts, mount => mount.Target == "/other-scripts" && mount.IsReadOnly);
    }

    [Fact]
    public async Task Sqlite_keeps_files_owned_by_the_local_Unix_user_and_uses_writable_runtime_directories()
    {
        var builder = CreateBuilder();
        var database = builder.AddSqlite("appdb", _appHostDirectory, "demo.db");
        var migration = database.AddGrateMigration().WithScriptsFolder(CreateScripts());
        var environment = await GetEnvironment(builder, migration.Resource);
        var runtimeArguments = new List<object>();
        var context = new ContainerRuntimeArgsCallbackContext(runtimeArguments, CancellationToken.None);
        foreach (var annotation in migration.Resource.Annotations.OfType<ContainerRuntimeArgsCallbackAnnotation>())
        {
            await annotation.Callback(context);
        }

        Assert.Equal("/tmp/grate-bundle", environment["DOTNET_BUNDLE_EXTRACT_BASE_DIR"]);
        Assert.Equal("/tmp/grate-output", environment["GRATE_OUTPUT_PATH"]);
        if (OperatingSystem.IsLinux() || OperatingSystem.IsMacOS() || OperatingSystem.IsFreeBSD())
        {
            var expectedUser = $"{await GetId("-u")}:{await GetId("-g")}";
            Assert.Equal(new object[] { "--user", expectedUser }, runtimeArguments);
        }
        else
        {
            Assert.Empty(runtimeArguments);
        }
    }

    [Theory]
    [InlineData(":memory:")]
    [InlineData("file:demo?mode=memory&cache=shared")]
    [InlineData("demo.db;Mode=Memory")]
    public void Sqlite_rejects_in_memory_and_URI_sources(string fileName)
    {
        var builder = CreateBuilder();
        var database = builder.AddSqlite("appdb", _appHostDirectory, fileName);

        Assert.Throws<NotSupportedException>(() => database.AddGrateMigration());
        Assert.Empty(builder.Resources.OfType<GrateMigrationResource>());
    }

    [Fact]
    public void Sqlite_rejects_relative_file_paths_instead_of_guessing_consumer_working_directories()
    {
        var builder = CreateBuilder();
        var database = builder.AddSqlite("appdb", "relative", "demo.db");

        Assert.Throws<NotSupportedException>(() => database.AddGrateMigration());
    }

    [Theory]
    [InlineData("data;files", "demo.db")]
    [InlineData("data", "demo.db ")]
    public void Sqlite_rejects_paths_that_the_host_connection_cannot_preserve(string directoryName, string fileName)
    {
        var builder = CreateBuilder();
        var database = builder.AddSqlite("appdb", Path.Combine(_appHostDirectory, directoryName), fileName);

        Assert.Throws<NotSupportedException>(() => database.AddGrateMigration());
        Assert.Empty(builder.Resources.OfType<GrateMigrationResource>());
    }

    [Fact]
    public void Sqlite_requires_a_dedicated_directory_instead_of_mounting_the_default_shared_temp_root()
    {
        var builder = CreateBuilder();
        var database = builder.AddSqlite("appdb");

        Assert.Throws<ArgumentException>(() => database.AddGrateMigration());
    }

    [Theory]
    [InlineData("/grate-data")]
    [InlineData("/grate-data/sql")]
    [InlineData("/grate-data/./")]
    [InlineData("/grate-data/../sql")]
    [InlineData("/.")]
    public void Sqlite_data_cannot_be_hidden_by_an_overlapping_or_ambiguous_scripts_mount(string target)
    {
        var builder = CreateBuilder();
        var database = builder.AddSqlite("appdb", _appHostDirectory, "demo.db");
        var migration = database.AddGrateMigration();

        Assert.Throws<ArgumentException>(() => migration.WithScriptsFolder(CreateScripts(), target));
        var mount = Assert.Single(migration.Resource.Annotations.OfType<ContainerMountAnnotation>());
        Assert.Equal("/grate-data", mount.Target);
        Assert.False(mount.IsReadOnly);
    }

    [Fact]
    public void Sqlite_data_cannot_be_hidden_by_an_ancestor_scripts_mount()
    {
        var builder = CreateBuilder();
        var database = builder.AddSqlite("appdb", _appHostDirectory, "demo.db");
        var migration = database.AddGrateMigration(containerDataPath: "/data/sqlite");

        Assert.Throws<ArgumentException>(() => migration.WithScriptsFolder(CreateScripts(), "/data"));
    }

    private IDistributedApplicationBuilder CreateBuilder() => DistributedApplication.CreateBuilder(
        new DistributedApplicationOptions { ProjectDirectory = _appHostDirectory, Args = [], DisableDashboard = true });

    private string CreateScripts(string name = "db") => Directory.CreateDirectory(Path.Combine(_appHostDirectory, name)).FullName;

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

    private static async Task<IList<object>> GetArguments(IResource resource)
    {
        var arguments = new List<object>();
        var context = new CommandLineArgsCallbackContext(arguments, resource, CancellationToken.None);
        foreach (var annotation in resource.Annotations.OfType<CommandLineArgsCallbackAnnotation>())
        {
            await annotation.Callback(context);
        }
        return arguments;
    }

    private static async Task<string> GetId(string argument)
    {
        using var process = Process.Start(new ProcessStartInfo("id", argument)
        {
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            UseShellExecute = false
        }) ?? throw new InvalidOperationException("Could not start the system identity command.");
        using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(10));
        var output = await process.StandardOutput.ReadToEndAsync(timeout.Token);
        await process.WaitForExitAsync(timeout.Token);
        Assert.Equal(0, process.ExitCode);
        return output.Trim();
    }

    public void Dispose() => Directory.Delete(_appHostDirectory, recursive: true);
}
