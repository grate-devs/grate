// These tests exercise the adapter's pinned Aspire 13.6.5 Kubernetes publishing contract.
#pragma warning disable ASPIREPIPELINES001
// The pinned native registry APIs are experimental; these tests verify their deployment contract.
#pragma warning disable ASPIRECOMPUTE003

using Aspire.Hosting;
using Aspire.Hosting.ApplicationModel;
using Aspire.Hosting.Kubernetes;
using Aspire.Hosting.Kubernetes.Resources;
using Aspire.Hosting.Pipelines;
using Grate.Aspire.Hosting;
using Grate.Aspire.Kubernetes;
using Microsoft.Extensions.DependencyInjection;
using Xunit;

namespace Grate.Aspire.Kubernetes.Tests;

public sealed class InitContainerTests : IDisposable
{
    private readonly string _directory = Directory.CreateTempSubdirectory("grate-kubernetes-").FullName;

    [Fact]
    public void Local_run_adds_only_the_explicit_successful_completion_wait()
    {
        var builder = CreateBuilder(publish: false);
        var migration = CreateMigration(builder);
        var application = builder.AddContainer("api", "example/api", "1")
            .WithGrateMigrationInitContainer(migration, environment: "PRODUCTION");

        var wait = Assert.Single(application.Resource.Annotations.OfType<WaitAnnotation>());
        Assert.Same(migration.Resource, wait.Resource);
        Assert.Equal(WaitType.WaitForCompletion, wait.WaitType);
        Assert.Equal(0, wait.ExitCode);
        Assert.Empty(migration.Resource.Annotations.OfType<DockerfileBuildAnnotation>());
        Assert.Empty(application.Resource.Annotations.OfType<KubernetesServiceCustomizationAnnotation>());
        Assert.Single(migration.Resource.Annotations.OfType<ContainerMountAnnotation>());
    }

    [Fact]
    public void Publish_preserves_native_build_and_push_without_a_standalone_workload()
    {
        var builder = CreateBuilder();
        var environment = AddEnvironment(builder);
        var migration = CreateMigration(builder);
        var application = builder.AddContainer("api", "example/api", "1")
            .WithGrateMigrationInitContainer(migration, environment: "PRODUCTION");

        Assert.True(migration.Resource.RequiresImageBuildAndPush());
        Assert.Single(migration.Resource.Annotations.OfType<DockerfileBuildAnnotation>());
        Assert.Empty(migration.Resource.Annotations.OfType<ContainerMountAnnotation>());
        var target = Assert.Single(migration.Resource.Annotations.OfType<DeploymentTargetAnnotation>());
        Assert.Same(environment.Resource, target.ComputeEnvironment);
        Assert.Same(Assert.Single(builder.Resources.OfType<IContainerRegistry>()), target.ContainerRegistry);
        Assert.IsNotType<KubernetesResource>(target.DeploymentTarget);
        Assert.Empty(target.DeploymentTarget.Annotations.OfType<PipelineStepAnnotation>());
        Assert.Single(application.Resource.Annotations.OfType<KubernetesServiceCustomizationAnnotation>());
    }

    [Fact]
    public void SQLite_is_rejected_before_packaging_a_host_path()
    {
        var builder = CreateBuilder();
        AddEnvironment(builder);
        var migration = builder.AddSqlite("appdb", Path.Combine(_directory, "data"), "app.db")
            .AddGrateMigration().WithScriptsFolder(Scripts());
        var application = builder.AddContainer("api", "example/api", "1");

        var error = Assert.Throws<NotSupportedException>(() => application.WithGrateMigrationInitContainer(migration, environment: "PRODUCTION"));

        Assert.Contains("SQLite", error.Message);
        Assert.Empty(migration.Resource.Annotations.OfType<DockerfileBuildAnnotation>());
    }

    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public void Missing_or_ambiguous_environment_is_rejected(bool ambiguous)
    {
        var builder = CreateBuilder();
        if (ambiguous)
        {
            builder.AddKubernetesEnvironment("one");
            builder.AddKubernetesEnvironment("two");
        }
        var migration = CreateMigration(builder);
        var application = builder.AddContainer("api", "example/api", "1");

        Assert.Throws<InvalidOperationException>(() => application.WithGrateMigrationInitContainer(migration, environment: "PRODUCTION"));
        Assert.Empty(migration.Resource.Annotations.OfType<DockerfileBuildAnnotation>());
    }

    [Fact]
    public void An_explicit_environment_and_registry_resolve_ambiguity()
    {
        var builder = CreateBuilder();
        var environment = AddEnvironment(builder);
        builder.AddKubernetesEnvironment("other");
        builder.AddContainerRegistry("other-registry", "other.example");
        var migration = CreateMigration(builder);

        builder.AddContainer("api", "example/api", "1").WithComputeEnvironment(environment)
            .WithGrateMigrationInitContainer(migration, environment: "PRODUCTION");

        Assert.Same(environment.Resource, migration.Resource.GetComputeEnvironment());
        Assert.Same(builder.Resources.OfType<ContainerRegistryResource>().Single(item => item.Name == "registry"),
            migration.Resource.GetDeploymentTargetAnnotation()?.ContainerRegistry);
    }

    [Fact]
    public void A_registry_is_required_for_the_built_migration_image()
    {
        var builder = CreateBuilder();
        builder.AddKubernetesEnvironment("environment");
        var migration = CreateMigration(builder);

        Assert.Throws<InvalidOperationException>(() => builder.AddContainer("api", "example/api", "1")
            .WithGrateMigrationInitContainer(migration, environment: "PRODUCTION"));
        Assert.Empty(migration.Resource.Annotations.OfType<DockerfileBuildAnnotation>());
    }

    [Fact]
    public async Task Staging_keeps_secret_and_image_references_deferred()
    {
        var builder = CreateBuilder();
        AddEnvironment(builder);
        var secret = builder.AddParameter("database-secret", secret: true);
        var migration = CreateMigration(builder).WithEnvironment("APP_CONNSTRING", secret);
        var application = builder.AddContainer("api", "example/api", "1")
            .WithGrateMigrationInitContainer(migration, environment: "PRODUCTION");

        var values = await EnvironmentValues(builder, application.Resource);

        Assert.Same(secret.Resource, values["GRATE_INIT_APPDB_GRATE_ENV_APP_CONNSTRING"]);
        Assert.Equal("PRODUCTION", values["GRATE_INIT_APPDB_GRATE_ENV_ENVIRONMENT"]);
        Assert.Same(migration.Resource, Assert.IsType<ContainerImageReference>(values["GRATE_INIT_APPDB_GRATE_IMAGE"]).Resource);
        Assert.DoesNotContain(values.Values, value => value is string text && text.Contains("Host=", StringComparison.Ordinal));
    }

    [Theory]
    [InlineData("literal")]
    [InlineData("default")]
    [InlineData("argument")]
    public async Task Unsafe_connection_defaults_and_dynamic_arguments_fail_without_disclosing_values(string kind)
    {
        var builder = CreateBuilder();
        AddEnvironment(builder);
        var migration = CreateMigration(builder);
        if (kind == "literal")
        {
            migration.WithEnvironment("APP_CONNSTRING", "Host=database;Password=private-marker");
        }
        else if (kind == "default")
        {
            migration.WithEnvironment("APP_CONNSTRING", builder.AddParameter("bad-secret", "private-marker", publishValueAsDefault: true));
        }
        else
        {
            migration.WithArgs(builder.AddParameter("argument-secret", secret: true).Resource);
        }
        var application = builder.AddContainer("api", "example/api", "1")
            .WithGrateMigrationInitContainer(migration, environment: "PRODUCTION");

        var error = await Record.ExceptionAsync(() => EnvironmentValues(builder, application.Resource));

        Assert.NotNull(error);
        if (kind == "argument")
        {
            Assert.IsType<NotSupportedException>(error);
        }
        else
        {
            Assert.IsType<InvalidOperationException>(error);
        }
        Assert.DoesNotContain("private-marker", error.Message);
    }

    [Fact]
    public void A_nonzero_wait_and_duplicate_attachment_are_rejected_early()
    {
        var builder = CreateBuilder();
        AddEnvironment(builder);
        var migration = CreateMigration(builder);
        var nonzero = builder.AddContainer("nonzero", "example/api", "1").WaitForCompletion(migration, 1);
        Assert.Throws<InvalidOperationException>(() => nonzero.WithGrateMigrationInitContainer(migration, environment: "PRODUCTION"));
        Assert.Empty(migration.Resource.Annotations.OfType<DockerfileBuildAnnotation>());
        var application = builder.AddContainer("api", "example/api", "1").WaitForCompletion(migration)
            .WithGrateMigrationInitContainer(migration, environment: "PRODUCTION");

        Assert.Throws<InvalidOperationException>(() => application.WithGrateMigrationInitContainer(migration, environment: "STAGING"));

        Assert.Single(application.Resource.Annotations.OfType<WaitAnnotation>());
        Assert.Single(application.Resource.Annotations.OfType<KubernetesServiceCustomizationAnnotation>());
    }

    [Fact]
    public async Task Shared_migration_keeps_per_consumer_deployment_environments_and_local_defaults()
    {
        var builder = CreateBuilder();
        AddEnvironment(builder);
        var migration = CreateMigration(builder);
        var production = builder.AddContainer("production", "example/api", "1")
            .WithGrateMigrationInitContainer(migration, environment: "PRODUCTION");
        var staging = builder.AddContainer("staging", "example/api", "1")
            .WithGrateMigrationInitContainer(migration, environment: "STAGING");

        Assert.Equal("PRODUCTION", (await EnvironmentValues(builder, production.Resource))["GRATE_INIT_APPDB_GRATE_ENV_ENVIRONMENT"]);
        Assert.Equal("STAGING", (await EnvironmentValues(builder, staging.Resource))["GRATE_INIT_APPDB_GRATE_ENV_ENVIRONMENT"]);
        Assert.Equal("LOCAL", (await EnvironmentValues(builder, migration.Resource))["ENVIRONMENT"]);
        Assert.Single(migration.Resource.Annotations.OfType<DockerfileBuildAnnotation>());
    }

    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public async Task Native_environment_is_moved_into_init_only_maps_preserving_workload_settings(bool stateful)
    {
        var builder = CreateBuilder();
        var environment = AddEnvironment(builder);
        var migration = CreateMigration(builder).WithArgs("--version", "release one");
        var application = builder.AddContainer("api", "example/api", "1")
            .WithGrateMigrationInitContainer(migration, environment: "PRODUCTION");
        await EnvironmentValues(builder, application.Resource);
        var binding = Assert.Single(application.Resource.Annotations.OfType<GrateKubernetesExtensions.InitBinding>());
        var resource = NativeModel(application.Resource, environment.Resource, binding, stateful);
        var pod = resource.Workload!.PodTemplate.Spec;
        var originalSecurity = pod.SecurityContext = new PodSecurityContextV1 { RunAsNonRoot = true };
        pod.ImagePullSecrets.Add(new LocalObjectReferenceV1 { Name = "registry-pull" });
        pod.TerminationGracePeriodSeconds = 17;
        var primary = Assert.Single(pod.Containers);
        var originalEnvFrom = primary.EnvFrom.ToArray();

        Assert.Single(application.Resource.Annotations.OfType<KubernetesServiceCustomizationAnnotation>()).Configure(resource);

        var init = Assert.Single(pod.InitContainers);
        Assert.Equal("appdb-grate", init.Name);
        Assert.Equal("/bin/sh", Assert.Single(init.Command));
        Assert.Equal("release one", init.Args[^1]);
        Assert.Contains("{{ .Values.config.api.GRATE_INIT_APPDB_GRATE_IMAGE", init.Image);
        var connection = Assert.Single(init.Env, variable => variable.Name == "APP_CONNSTRING");
        Assert.Equal("api-appdb-grate-init-secret", connection.ValueFrom?.SecretKeyRef?.Name);
        Assert.Null(connection.ValueFrom?.ConfigMapKeyRef);
        Assert.Equal("APP_CONNSTRING", connection.ValueFrom?.SecretKeyRef?.Key);
        Assert.Equal("preserved", resource.ConfigMap!.Data["APPLICATION_SETTING"]);
        Assert.Equal("other-secret", resource.Secret!.StringData["APPLICATION_SECRET"]);
        Assert.Equal("{{ tpl \"{{ .Values.config.api.APPLICATION_DYNAMIC }}\" . | quote }}",
            resource.ConfigMap.Data["APPLICATION_DYNAMIC"]);
        Assert.Equal("{{ tpl \"{{ .Values.secrets.api.appdb }}\" . | quote }}",
            resource.Secret.StringData["CONSUMER_CONNECTION"]);
        Assert.DoesNotContain(resource.ConfigMap.Data.Keys, key => key.StartsWith(binding.Prefix, StringComparison.Ordinal));
        Assert.DoesNotContain(resource.Secret.StringData.Keys, key => key.StartsWith(binding.Prefix, StringComparison.Ordinal));
        Assert.Equal(originalEnvFrom, primary.EnvFrom);
        Assert.Same(originalSecurity, pod.SecurityContext);
        Assert.Equal("registry-pull", Assert.Single(pod.ImagePullSecrets).Name);
        Assert.Equal(17, pod.TerminationGracePeriodSeconds);
        var initSecret = Assert.Single(resource.AdditionalResources.OfType<Secret>());
        Assert.Equal("{{ tpl \"{{ .Values.secrets.api.appdb }}\" . | quote }}",
            initSecret.StringData["APP_CONNSTRING"]);
    }

    [Fact]
    public async Task A_plaintext_native_connection_and_existing_init_name_are_rejected()
    {
        var builder = CreateBuilder();
        var environment = AddEnvironment(builder);
        var migration = CreateMigration(builder);
        var application = builder.AddContainer("api", "example/api", "1")
            .WithGrateMigrationInitContainer(migration, environment: "PRODUCTION");
        await EnvironmentValues(builder, application.Resource);
        var binding = Assert.Single(application.Resource.Annotations.OfType<GrateKubernetesExtensions.InitBinding>());
        var resource = NativeModel(application.Resource, environment.Resource, binding);
        resource.Secret!.StringData.Remove($"{binding.Prefix}ENV_APP_CONNSTRING");
        resource.ConfigMap!.Data[$"{binding.Prefix}ENV_APP_CONNSTRING"] = "private-marker";
        var error = Assert.Throws<InvalidOperationException>(() => GrateKubernetesExtensions.ConfigureInitContainer(resource, binding));
        Assert.DoesNotContain("private-marker", error.Message);
        var duplicate = NativeModel(application.Resource, environment.Resource, binding);
        duplicate.Workload!.PodTemplate.Spec.InitContainers.Add(new ContainerV1 { Name = migration.Resource.Name });
        Assert.Throws<InvalidOperationException>(() => GrateKubernetesExtensions.ConfigureInitContainer(duplicate, binding));
    }

    [Theory]
    [InlineData("http", "HTTP")]
    [InlineData("https", "HTTPS")]
    [InlineData("hTtP", "HTTP")]
    [InlineData("HTTP", "HTTP")]
    [InlineData("HTTPS", "HTTPS")]
    [InlineData("{{ .Values.probeScheme }}", "{{ .Values.probeScheme }}")]
    [InlineData("ftp", "ftp")]
    public async Task HTTP_probe_schemes_match_Kubernetes_schema_without_changing_probe_configuration(string scheme, string expected)
    {
        var builder = CreateBuilder();
        var environment = AddEnvironment(builder);
        var application = builder.AddContainer("api", "example/api", "1")
            .WithGrateMigrationInitContainer(CreateMigration(builder), environment: "PRODUCTION");
        await EnvironmentValues(builder, application.Resource);
        var binding = Assert.Single(application.Resource.Annotations.OfType<GrateKubernetesExtensions.InitBinding>());
        var resource = NativeModel(application.Resource, environment.Resource, binding);
        var pod = resource.Workload!.PodTemplate.Spec;
        pod.ImagePullSecrets.Add(new LocalObjectReferenceV1 { Name = "registry-pull" });
        var primary = Assert.Single(pod.Containers);
        primary.ImagePullPolicy = "Always";
        var probes = Enumerable.Range(0, 3).Select(index => new ProbeV1
        {
            HttpGet = new HttpGetActionV1 { Scheme = scheme, Path = $"/health/{index}", Port = 8080, Host = "localhost" },
            TimeoutSeconds = 7,
            PeriodSeconds = 11,
            InitialDelaySeconds = 13,
            FailureThreshold = 5,
            SuccessThreshold = 1,
            TerminationGracePeriodSeconds = 19
        }).ToArray();
        primary.ReadinessProbe = probes[0];
        primary.LivenessProbe = probes[1];
        primary.StartupProbe = probes[2];
        foreach (var probe in probes)
        {
            probe.HttpGet!.HttpHeaders.Add(new HttpHeaderV1 { Name = "X-Probe", Value = "preserved" });
        }
        var tcpProbe = new ProbeV1 { TcpSocket = new TcpSocketActionV1 { Port = 9000 }, TimeoutSeconds = 3 };
        pod.Containers.Add(new ContainerV1 { Name = "worker", Image = "example/worker:1", ReadinessProbe = tcpProbe });

        GrateKubernetesExtensions.ConfigureInitContainer(resource, binding);

        Assert.Same(probes[0], primary.ReadinessProbe);
        Assert.Same(probes[1], primary.LivenessProbe);
        Assert.Same(probes[2], primary.StartupProbe);
        for (var index = 0; index < probes.Length; index++)
        {
            var probe = probes[index];
            Assert.Equal(expected, probe.HttpGet!.Scheme);
            Assert.Equal($"/health/{index}", probe.HttpGet.Path);
            Assert.Equal(8080, probe.HttpGet.Port!.Number);
            Assert.Equal("localhost", probe.HttpGet.Host);
            Assert.Equal("preserved", Assert.Single(probe.HttpGet.HttpHeaders).Value);
            Assert.Equal(7, probe.TimeoutSeconds);
            Assert.Equal(11, probe.PeriodSeconds);
            Assert.Equal(13, probe.InitialDelaySeconds);
            Assert.Equal(5, probe.FailureThreshold);
            Assert.Equal(1, probe.SuccessThreshold);
            Assert.Equal(19, probe.TerminationGracePeriodSeconds);
        }
        Assert.Same(tcpProbe, pod.Containers[1].ReadinessProbe);
        Assert.Null(tcpProbe.HttpGet);
        Assert.Equal(9000, tcpProbe.TcpSocket!.Port);
        Assert.Equal(3, tcpProbe.TimeoutSeconds);
        Assert.Equal("Always", primary.ImagePullPolicy);
        Assert.Equal("registry-pull", Assert.Single(pod.ImagePullSecrets).Name);
    }

    [Theory]
    [InlineData("GRATE_INIT_APPDB_GRATE_CUSTOM")]
    [InlineData("grate_init_appdb_grate_custom")]
    [InlineData("GRATE-INIT-APPDB-GRATE-CUSTOM")]
    public async Task A_reserved_staging_prefix_collision_is_rejected(string key)
    {
        var builder = CreateBuilder();
        AddEnvironment(builder);
        var application = builder.AddContainer("api", "example/api", "1")
            .WithEnvironment(key, "preserved")
            .WithGrateMigrationInitContainer(CreateMigration(builder), environment: "PRODUCTION");

        await Assert.ThrowsAsync<InvalidOperationException>(() => EnvironmentValues(builder, application.Resource));
    }

    [Fact]
    public async Task An_unsupported_workload_is_rejected_explicitly()
    {
        var builder = CreateBuilder();
        var environment = AddEnvironment(builder);
        var application = builder.AddContainer("api", "example/api", "1")
            .WithGrateMigrationInitContainer(CreateMigration(builder), environment: "PRODUCTION");
        await EnvironmentValues(builder, application.Resource);
        var binding = Assert.Single(application.Resource.Annotations.OfType<GrateKubernetesExtensions.InitBinding>());
        var resource = NativeModel(application.Resource, environment.Resource, binding);
        resource.Workload = new UnsupportedWorkload();

        var error = Assert.Throws<NotSupportedException>(() => GrateKubernetesExtensions.ConfigureInitContainer(resource, binding));

        Assert.Contains("Deployments and StatefulSets", error.Message);
        Assert.Empty(resource.Workload.PodTemplate.Spec.InitContainers);
    }

    [Fact]
    public async Task Generated_map_names_cannot_replace_existing_custom_resources()
    {
        var builder = CreateBuilder();
        var environment = AddEnvironment(builder);
        var application = builder.AddContainer("api", "example/api", "1")
            .WithGrateMigrationInitContainer(CreateMigration(builder), environment: "PRODUCTION");
        await EnvironmentValues(builder, application.Resource);
        var binding = Assert.Single(application.Resource.Annotations.OfType<GrateKubernetesExtensions.InitBinding>());
        var resource = NativeModel(application.Resource, environment.Resource, binding);
        var existing = new ConfigMap();
        existing.Metadata.Name = "api-appdb-grate-init-config";
        existing.Data.Add("CUSTOM", "retained");
        resource.AdditionalResources.Add(existing);

        Assert.Throws<InvalidOperationException>(() => GrateKubernetesExtensions.ConfigureInitContainer(resource, binding));

        Assert.Same(existing, Assert.Single(resource.AdditionalResources));
        Assert.Equal("retained", existing.Data["CUSTOM"]);
        Assert.Empty(resource.Workload!.PodTemplate.Spec.InitContainers);
    }

    [Fact]
    public void Actual_Helm_deployment_waits_for_the_migration_image_push()
    {
        var builder = CreateBuilder();
        var environment = AddEnvironment(builder);
        var migration = CreateMigration(builder);
        var application = builder.AddContainer("api", "example/api", "1")
            .WithGrateMigrationInitContainer(migration, environment: "PRODUCTION");
        application.Resource.Annotations.Add(new DeploymentTargetAnnotation(new KubernetesResource("api", application.Resource, environment.Resource))
        { ComputeEnvironment = environment.Resource });
        var push = new PipelineStep { Name = "push-migration", Resource = migration.Resource, Action = _ => Task.CompletedTask, Tags = [WellKnownPipelineTags.PushContainerImage] };
        var deploy = new PipelineStep { Name = "helm-deploy-environment", Resource = environment.Resource, Action = _ => Task.CompletedTask, Tags = ["helm-deploy"] };
        var unrelated = new PipelineStep { Name = "other", Resource = environment.Resource, Action = _ => Task.CompletedTask };

        ConfigurePipeline(builder, application.Resource, [push, deploy, unrelated]);

        Assert.Contains(push.Name, deploy.DependsOnSteps);
        Assert.Empty(unrelated.DependsOnSteps);
        Assert.Throws<InvalidOperationException>(() => ConfigurePipeline(builder, application.Resource, [deploy]));
    }

    [Theory]
    [InlineData("none")]
    [InlineData("application")]
    [InlineData("migration")]
    [InlineData("registry")]
    public void Late_retargeting_fails_closed_but_initial_unprepared_target_is_valid(string retarget)
    {
        var builder = CreateBuilder();
        var one = AddEnvironment(builder);
        var two = builder.AddKubernetesEnvironment("two");
        var migration = CreateMigration(builder);
        var application = builder.AddContainer("api", "example/api", "1").WithComputeEnvironment(one)
            .WithGrateMigrationInitContainer(migration, environment: "PRODUCTION");
        if (retarget == "application")
        {
            application.WithComputeEnvironment(two);
        }
        else if (retarget == "migration")
        {
            migration.WithComputeEnvironment(two);
        }
        else if (retarget == "registry")
        {
            one.WithContainerRegistry(builder.AddContainerRegistry("other-registry", "other.example"));
        }

        if (retarget == "none")
        {
            ConfigurePipeline(builder, application.Resource, []);
        }
        else
        {
            Assert.Throws<InvalidOperationException>(() => ConfigurePipeline(builder, application.Resource, []));
        }
    }

    private static KubernetesResource NativeModel(IResource application, KubernetesEnvironmentResource environment,
        GrateKubernetesExtensions.InitBinding binding, bool stateful = false)
    {
        var resource = new KubernetesResource(application.Name, application, environment)
        {
            Workload = stateful ? new StatefulSet() : new Deployment(),
            ConfigMap = new ConfigMap(),
            Secret = new Secret()
        };
        resource.ConfigMap.Metadata.Name = "api-config";
        resource.Secret.Metadata.Name = "api-secrets";
        resource.ConfigMap.Data.Add("APPLICATION_SETTING", "preserved");
        resource.ConfigMap.Data.Add("APPLICATION_DYNAMIC", "{{ .Values.config.api.APPLICATION_DYNAMIC }}");
        resource.ConfigMap.Data.Add($"{binding.Prefix}IMAGE", "{{ .Values.config.api.GRATE_INIT_APPDB_GRATE_IMAGE }}");
        resource.ConfigMap.Data.Add($"{binding.Prefix}ENV_DATABASE_TYPE", "{{ .Values.config.api.GRATE_INIT_APPDB_GRATE_ENV_DATABASE_TYPE }}");
        resource.Secret.StringData.Add("APPLICATION_SECRET", "other-secret");
        resource.Secret.StringData.Add("CONSUMER_CONNECTION", "{{ .Values.secrets.api.appdb }}");
        resource.Secret.StringData.Add($"{binding.Prefix}ENV_APP_CONNSTRING", "{{ .Values.secrets.api.appdb }}");
        var primary = new ContainerV1 { Name = "api", Image = "example/api:1" };
        primary.EnvFrom.Add(new EnvFromSourceV1 { ConfigMapRef = new ConfigMapEnvSourceV1 { Name = "api-config" } });
        primary.EnvFrom.Add(new EnvFromSourceV1 { SecretRef = new SecretEnvSourceV1 { Name = "api-secrets" } });
        resource.Workload.PodTemplate.Spec.Containers.Add(primary);
        return resource;
    }

    private static void ConfigurePipeline(IDistributedApplicationBuilder builder, IResource application, PipelineStep[] steps)
    {
        using var services = builder.Services.BuildServiceProvider();
        var context = new PipelineConfigurationContext { Services = services, Model = new DistributedApplicationModel(builder.Resources), Steps = steps };
        foreach (var annotation in application.Annotations.OfType<PipelineConfigurationAnnotation>())
        {
            annotation.Callback(context);
        }
    }

    private static async Task<Dictionary<string, object>> EnvironmentValues(IDistributedApplicationBuilder builder, IResource resource)
    {
        var values = new Dictionary<string, object>();
        var context = new EnvironmentCallbackContext(builder.ExecutionContext, resource, values, CancellationToken.None);
        foreach (var callback in resource.Annotations.OfType<EnvironmentCallbackAnnotation>())
        {
            await callback.Callback(context);
        }
        return values;
    }

    private static IResourceBuilder<KubernetesEnvironmentResource> AddEnvironment(IDistributedApplicationBuilder builder) =>
        builder.AddKubernetesEnvironment("environment").WithContainerRegistry(builder.AddContainerRegistry("registry", "registry.example", "grate"));

    private IDistributedApplicationBuilder CreateBuilder(bool publish = true) => DistributedApplication.CreateBuilder(
        new DistributedApplicationOptions
        {
            ProjectDirectory = _directory,
            DisableDashboard = true,
            Args = publish ? ["--publisher", "manifest", "--output-path", Path.Combine(_directory, "publish")] : []
        });

    private IResourceBuilder<GrateMigrationResource> CreateMigration(IDistributedApplicationBuilder builder) =>
        builder.AddConnectionString("appdb").AddGrateMigration(GrateDatabaseProvider.PostgreSql).WithScriptsFolder(Scripts());

    private string Scripts() => Directory.CreateDirectory(Path.Combine(_directory, "sql")).FullName;

    private sealed class UnsupportedWorkload() : Workload("example/v1", "Unsupported")
    {
        public override PodTemplateSpecV1 PodTemplate { get; } = new();
    }

    public void Dispose() => Directory.Delete(_directory, recursive: true);
}

#pragma warning restore ASPIREPIPELINES001
#pragma warning restore ASPIRECOMPUTE003
