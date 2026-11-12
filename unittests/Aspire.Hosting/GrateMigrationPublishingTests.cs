using System.Text.Json;
using Aspire.Hosting;
using Aspire.Hosting.ApplicationModel;
using Grate.Aspire.Hosting;
using Microsoft.Extensions.DependencyInjection;
using Xunit;

namespace AspireHosting.Tests;

public sealed class GrateMigrationPublishingTests : IDisposable
{
    private readonly string _appHostDirectory = Directory.CreateTempSubdirectory("grate-publish-tests-").FullName;
    private readonly HashSet<string> _contexts = [];

    [Theory]
    [InlineData(GrateDatabaseProvider.PostgreSql, "postgresql")]
    [InlineData(GrateDatabaseProvider.SqlServer, "sqlserver")]
    [InlineData(GrateDatabaseProvider.Oracle, "oracle")]
    [InlineData(GrateDatabaseProvider.MySql, "mariadb")]
    [InlineData(GrateDatabaseProvider.MariaDb, "mariadb")]
    public async Task Existing_database_parameters_require_an_explicit_provider_and_keep_credentials_deferred(
        GrateDatabaseProvider provider, string expectedType)
    {
        var builder = CreateBuilder(publish: true);
        var database = builder.AddConnectionString("existing-database");

        var migration = database.AddGrateMigration(provider).WithScriptsFolder(CreateScripts());
        var environment = await GetEnvironment(builder, migration.Resource);

        Assert.Equal(expectedType, environment["DATABASE_TYPE"]);
        Assert.Equal("false", environment["CREATE_DATABASE"]);
        Assert.Equal(database.Resource.ConnectionStringExpression.ValueExpression,
            Assert.IsType<ReferenceExpression>(environment["APP_CONNSTRING"]).ValueExpression);
        Assert.Same(database.Resource, Assert.Single(migration.Resource.Annotations.OfType<WaitAnnotation>()).Resource);
        Assert.False(migration.Resource.UsesSharedDatabaseFile);
    }

    [Fact]
    public void Unsupported_explicit_providers_do_not_register_a_migration()
    {
        var builder = CreateBuilder(publish: true);
        var database = builder.AddConnectionString("appdb");

        Assert.Throws<ArgumentOutOfRangeException>(() => database.AddGrateMigration((GrateDatabaseProvider)42));
        Assert.Empty(builder.Resources.OfType<GrateMigrationResource>());
    }

    [Fact]
    public void A_SQLite_resource_cannot_bypass_its_file_contract_via_the_server_provider_overload()
    {
        var builder = CreateBuilder(publish: true);
        var database = builder.AddSqlite("appdb", _appHostDirectory, "demo.db");

        Assert.Throws<NotSupportedException>(() => database.AddGrateMigration(GrateDatabaseProvider.PostgreSql));
        Assert.Empty(builder.Resources.OfType<GrateMigrationResource>());
    }

    [Fact]
    public async Task Publishing_copies_only_the_SQL_tree_without_modifying_source_or_baking_runtime_secrets()
    {
        var builder = CreateBuilder(publish: true);
        var scripts = CreateScripts();
        var nested = Directory.CreateDirectory(Path.Combine(scripts, "up", "nested folder")).FullName;
        var bytes = new byte[] { 45, 45, 32, 83, 81, 76, 13, 10 };
        File.WriteAllBytes(Path.Combine(scripts, "up", "01_create.sql"), bytes);
        File.WriteAllText(Path.Combine(nested, "02 seed.SQL"), "SELECT 2;\n");
        File.WriteAllText(Path.Combine(scripts, ".env"), "DO_NOT_INCLUDE=source-secret");
        File.WriteAllText(Path.Combine(scripts, ".dockerignore"), "*.sql");
        File.WriteAllText(Path.Combine(scripts, "README.md"), "consumer notes");
        var originalFiles = Directory.GetFiles(scripts, "*", SearchOption.AllDirectories).Order().ToArray();
        var migration = builder.AddConnectionString("appdb")
            .AddGrateMigration(GrateDatabaseProvider.PostgreSql)
            .WithEnvironment("APP_CONNSTRING", "Host=example;Password=runtime-secret")
            .WithScriptsFolder(scripts, "/sql scripts");

        var build = Package(migration);
        var dockerfile = await GetDockerfile(build, migration.Resource);

        Assert.NotEqual(scripts, build.ContextPath);
        var packagedFiles = Directory.GetFiles(build.ContextPath, "*", SearchOption.AllDirectories)
            .Select(path => Path.GetRelativePath(build.ContextPath, path).Replace('\\', '/')).Order().ToArray();
        Assert.Equal(new[] { "up/01_create.sql", "up/nested folder/02 seed.SQL" }, packagedFiles);
        Assert.Equal(bytes, File.ReadAllBytes(Path.Combine(build.ContextPath, "up", "01_create.sql")));
        Assert.Equal(originalFiles, Directory.GetFiles(scripts, "*", SearchOption.AllDirectories).Order());
        Assert.Equal("*.sql", File.ReadAllText(Path.Combine(scripts, ".dockerignore")));
        Assert.Empty(migration.Resource.Annotations.OfType<ContainerMountAnnotation>());
        Assert.Empty(build.BuildArguments);
        Assert.Empty(build.BuildSecrets);
        Assert.DoesNotContain("runtime-secret", dockerfile);
        Assert.DoesNotContain(_appHostDirectory, dockerfile);
        Assert.Equal(new[] { ".", "/sql scripts/" }, GetCopyPaths(dockerfile));
        Assert.StartsWith("FROM gratedevs/grate:2.3.0\n", dockerfile);
    }

    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public async Task Published_base_image_respects_registry_tag_and_digest(bool useDigest)
    {
        var builder = CreateBuilder(publish: true);
        var migration = builder.AddConnectionString("appdb")
            .AddGrateMigration(GrateDatabaseProvider.SqlServer)
            .WithImage("custom/grate", "9.8.7")
            .WithImageRegistry("registry.example:5000")
            .WithScriptsFolder(CreateScripts(), "/sql \"quoted\" folder");
        var digest = new string('a', 64);
        if (useDigest)
        {
            migration.WithImageSHA256(digest);
        }

        var build = Package(migration);
        var dockerfile = await GetDockerfile(build, migration.Resource);

        var expectedImage = "registry.example:5000/custom/grate" + (useDigest ? $"@sha256:{digest}" : ":9.8.7");
        Assert.StartsWith($"FROM {expectedImage}\n", dockerfile);
        Assert.Equal(new[] { ".", "/sql \"quoted\" folder/" }, GetCopyPaths(dockerfile));
    }

    [Fact]
    public void Local_runs_keep_the_read_only_scripts_bind_and_do_not_build_an_image()
    {
        var builder = CreateBuilder(publish: false);
        var migration = builder.AddPostgres("postgres").AddDatabase("appdb")
            .AddGrateMigration().WithScriptsFolder(CreateScripts());
        var mount = Assert.Single(migration.Resource.Annotations.OfType<ContainerMountAnnotation>());

        migration.PublishAsGrateMigrationImage();

        Assert.Same(mount, Assert.Single(migration.Resource.Annotations.OfType<ContainerMountAnnotation>()));
        Assert.True(mount.IsReadOnly);
        Assert.Empty(migration.Resource.Annotations.OfType<DockerfileBuildAnnotation>());
    }

    [Fact]
    public void Publishing_requires_a_scripts_folder_and_preserves_state_when_it_is_missing()
    {
        var builder = CreateBuilder(publish: true);
        var migration = builder.AddConnectionString("appdb").AddGrateMigration(GrateDatabaseProvider.PostgreSql);

        Assert.Throws<InvalidOperationException>(() => migration.PublishAsGrateMigrationImage());
        Assert.Empty(migration.Resource.Annotations.OfType<DockerfileBuildAnnotation>());
    }

    [Fact]
    public void Publishing_rechecks_that_the_declared_source_still_exists()
    {
        var builder = CreateBuilder(publish: true);
        var scripts = CreateScripts();
        var migration = builder.AddConnectionString("appdb").AddGrateMigration(GrateDatabaseProvider.PostgreSql)
            .WithScriptsFolder(scripts);
        Directory.Delete(scripts, recursive: true);

        Assert.Throws<DirectoryNotFoundException>(() => migration.PublishAsGrateMigrationImage());
        Assert.Single(migration.Resource.Annotations.OfType<ContainerMountAnnotation>());
        Assert.Empty(migration.Resource.Annotations.OfType<DockerfileBuildAnnotation>());
    }

    [Fact]
    public void Publishing_rejects_an_existing_Dockerfile_build()
    {
        var builder = CreateBuilder(publish: true);
        var scripts = CreateScripts();
        var migration = builder.AddConnectionString("appdb").AddGrateMigration(GrateDatabaseProvider.PostgreSql)
            .WithScriptsFolder(scripts)
            .WithDockerfile(scripts);

        Assert.Throws<InvalidOperationException>(() => migration.PublishAsGrateMigrationImage());
        Assert.Single(migration.Resource.Annotations.OfType<ContainerMountAnnotation>());
    }

    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public void Publishing_rejects_additional_bind_mounts_and_volumes(bool useVolume)
    {
        var builder = CreateBuilder(publish: true);
        var migration = builder.AddConnectionString("appdb").AddGrateMigration(GrateDatabaseProvider.PostgreSql)
            .WithScriptsFolder(CreateScripts());
        if (useVolume)
        {
            migration.WithVolume("output", "/output");
        }
        else
        {
            migration.WithBindMount(_appHostDirectory, "/output");
        }

        Assert.Throws<InvalidOperationException>(() => migration.PublishAsGrateMigrationImage());
        Assert.Empty(migration.Resource.Annotations.OfType<DockerfileBuildAnnotation>());
    }

    [Fact]
    public void Shared_file_SQLite_does_not_claim_cloud_storage_support()
    {
        var builder = CreateBuilder(publish: true);
        var migration = builder.AddSqlite("appdb", _appHostDirectory, "demo.db")
            .AddGrateMigration().WithScriptsFolder(CreateScripts());

        Assert.True(migration.Resource.UsesSharedDatabaseFile);
        Assert.Throws<NotSupportedException>(() => migration.PublishAsGrateMigrationImage());
        Assert.Empty(migration.Resource.Annotations.OfType<DockerfileBuildAnnotation>());
    }

    [Fact]
    public void Packaging_is_idempotent_but_scripts_cannot_be_reconfigured_after_the_snapshot()
    {
        var builder = CreateBuilder(publish: true);
        var migration = builder.AddConnectionString("appdb").AddGrateMigration(GrateDatabaseProvider.PostgreSql)
            .WithScriptsFolder(CreateScripts());
        var first = Package(migration);

        migration.PublishAsGrateMigrationImage();

        Assert.Same(first, Assert.Single(migration.Resource.Annotations.OfType<DockerfileBuildAnnotation>()));
        Assert.Throws<InvalidOperationException>(() => migration.WithScriptsFolder(CreateScripts()));
    }

    [Fact]
    public async Task A_later_runtime_mount_cannot_silently_enter_the_published_model()
    {
        var builder = CreateBuilder(publish: true);
        var migration = builder.AddConnectionString("appdb").AddGrateMigration(GrateDatabaseProvider.PostgreSql)
            .WithScriptsFolder(CreateScripts());
        var build = Package(migration);
        migration.WithBindMount(_appHostDirectory, "/extra");

        await Assert.ThrowsAsync<InvalidOperationException>(() => GetDockerfile(build, migration.Resource));
        Assert.Throws<InvalidOperationException>(() => migration.PublishAsGrateMigrationImage());
    }

    [Fact]
    public void Publishing_rejects_symbolic_links_instead_of_reading_outside_the_SQL_tree()
    {
        if (OperatingSystem.IsWindows())
        {
            Assert.Skip("Creating symbolic links on Windows requires separate machine privileges.");
        }
        var builder = CreateBuilder(publish: true);
        var scripts = CreateScripts();
        var outsideFile = Path.Combine(_appHostDirectory, "outside-secret.sql");
        File.WriteAllText(outsideFile, "must not enter the context");
        File.CreateSymbolicLink(Path.Combine(scripts, "external.sql"), outsideFile);
        var migration = builder.AddConnectionString("appdb").AddGrateMigration(GrateDatabaseProvider.PostgreSql)
            .WithScriptsFolder(scripts);

        Assert.Throws<NotSupportedException>(() => migration.PublishAsGrateMigrationImage());
        Assert.Empty(migration.Resource.Annotations.OfType<DockerfileBuildAnnotation>());
        Assert.Single(migration.Resource.Annotations.OfType<ContainerMountAnnotation>());
    }

    private IDistributedApplicationBuilder CreateBuilder(bool publish) => DistributedApplication.CreateBuilder(
        new DistributedApplicationOptions
        {
            ProjectDirectory = _appHostDirectory,
            Args = publish ? ["--operation", "publish"] : [],
            DisableDashboard = true
        });

    private string CreateScripts() => Directory.CreateDirectory(Path.Combine(_appHostDirectory, "db")).FullName;

    private DockerfileBuildAnnotation Package(IResourceBuilder<GrateMigrationResource> migration)
    {
        migration.PublishAsGrateMigrationImage();
        var build = Assert.Single(migration.Resource.Annotations.OfType<DockerfileBuildAnnotation>());
        _contexts.Add(build.ContextPath);
        return build;
    }

    private static async Task<string> GetDockerfile(DockerfileBuildAnnotation build, IResource resource)
    {
        using var services = new ServiceCollection().BuildServiceProvider();
        return await Assert.IsType<Func<DockerfileFactoryContext, Task<string>>>(build.DockerfileFactory)(
            new DockerfileFactoryContext { Resource = resource, Services = services });
    }

    private static string[] GetCopyPaths(string dockerfile) =>
        JsonSerializer.Deserialize<string[]>(dockerfile.Split('\n').Single(line => line.StartsWith("COPY ", StringComparison.Ordinal))[5..])
        ?? throw new InvalidOperationException("The generated COPY instruction is not a JSON path array.");

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

    public void Dispose()
    {
        foreach (var context in _contexts)
        {
            if (Directory.Exists(context))
            {
                Directory.Delete(context, recursive: true);
            }
        }
        Directory.Delete(_appHostDirectory, recursive: true);
    }
}
