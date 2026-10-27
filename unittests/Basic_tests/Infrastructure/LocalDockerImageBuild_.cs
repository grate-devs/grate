using System.Diagnostics;
using System.Runtime.CompilerServices;
using System.Text;
using System.Xml.Linq;

namespace Basic_tests.Infrastructure;

public sealed class LocalDockerImageBuild_ : IDisposable
{
    private readonly string _root = Directory.CreateTempSubdirectory("grate image build tests-").FullName;
    private readonly HashSet<string> _plans = [];

    [Fact]
    public async Task A_normal_build_prepares_one_shared_plan_without_running_Docker()
    {
        var result = await PrepareCallers();

        Assert.True(result.ExitCode == 0, result.Output);
        Assert.Empty(BuildEvents());
        AssertCopyMarkers();
        var sidecars = Sidecars();
        Assert.Equal(6, sidecars.Length);
        var plan = File.ReadAllLines(sidecars[0]);
        Assert.Equal(3, plan.Length);
        Assert.Equal(RepositoryRoot(), Path.TrimEndingDirectorySeparator(plan[0]));
        Assert.Equal(DockerSpyPath, plan[1]);
        Assert.True(File.Exists(plan[2]), "The shared build plan must exist before it is copied.");
        Assert.Equal(plan, File.ReadAllLines(plan[2]));
        Assert.All(sidecars, sidecar => Assert.Equal(plan, File.ReadAllLines(sidecar)));
    }

    [Theory]
    [InlineData("CI")]
    [InlineData("ContinuousIntegrationBuild")]
    public async Task CI_builds_remove_stale_local_build_plans(string ciProperty)
    {
        var result = await PrepareCallers(property: $"{ciProperty}=true", seedStalePlans: true);

        Assert.True(result.ExitCode == 0, result.Output);
        Assert.Empty(BuildEvents());
        Assert.Empty(Sidecars());
        AssertCopyMarkers();
    }

    [Fact]
    public async Task An_explicit_application_image_removes_stale_local_build_plans()
    {
        var result = await PrepareCallers(
            property: "GrateTestConfig__ApplicationDockerImage=custom:tests", seedStalePlans: true);

        Assert.True(result.ExitCode == 0, result.Output);
        Assert.Empty(BuildEvents());
        Assert.Empty(Sidecars());
        AssertCopyMarkers();
    }

    [Fact]
    public async Task Disabling_the_local_image_build_removes_stale_plans()
    {
        var result = await PrepareCallers(property: "GrateBuildLocalDockerImage=false", seedStalePlans: true);

        Assert.True(result.ExitCode == 0, result.Output);
        Assert.Empty(BuildEvents());
        Assert.Empty(Sidecars());
        AssertCopyMarkers();
    }

    private async Task<(int ExitCode, string Output)> PrepareCallers(string? property = null, bool seedStalePlans = false)
    {
        var markers = Directory.CreateDirectory(Path.Combine(_root, "copy-markers")).FullName;
        var emptySources = Directory.CreateDirectory(Path.Combine(_root, "empty-sources")).FullName;
        var targets = Path.Combine(RepositoryRoot(), "unittests", "Docker", "IncludeTests.targets");

        foreach (var name in new[] { "caller-a", "caller-b" })
        {
            new XDocument(
                new XElement("Project",
                    new XAttribute("DefaultTargets", "CopyFilesToOutputDirectory"),
                    new XElement("PropertyGroup",
                        new XElement("ProjectToIncludeTestsFrom", emptySources),
                        new XElement("AssemblyName", name),
                        // Evaluated here rather than passed globally: TargetDir must not split the shared helper node.
                        new XElement("TargetDir", "$(OutputPath)/"),
                        new XElement("CI", "false"),
                        new XElement("ContinuousIntegrationBuild", "false")),
                    new XElement("Import", new XAttribute("Project", targets)),
                    new XElement("Target", new XAttribute("Name", "CopyFilesToOutputDirectory"),
                        new XElement("WriteLinesToFile",
                            new XAttribute("File", Path.Combine(markers, "$(MSBuildProjectName)-$(TargetFramework)-$(RuntimeIdentifier).txt")),
                            new XAttribute("Lines", "copied"),
                            new XAttribute("Overwrite", "false")))))
                .Save(Path.Combine(_root, name + ".proj"));
        }

        var callers = new XElement("ItemGroup");
        foreach (var name in new[] { "caller-a", "caller-b" })
        {
            foreach (var (framework, runtime, selfContained) in new[]
            {
                ("net8.0", "linux-x64", "false"),
                ("net9.0", "win-x64", "true"),
                ("net10.0", "osx-arm64", "false")
            })
            {
                var output = Path.Combine(_root, "output", name, framework);
                Directory.CreateDirectory(output);
                if (seedStalePlans)
                {
                    File.WriteAllLines(Path.Combine(output, name + ".docker-build"),
                        ["stale repository", "stale executable", "stale plan"]);
                }
                callers.Add(new XElement("Caller",
                    new XAttribute("Include", Path.Combine(_root, name + ".proj")),
                    new XElement("AdditionalProperties",
                        $"TargetFramework={framework};RuntimeIdentifier={runtime};SelfContained={selfContained};" +
                        $"OutputPath={output};OutDir={output};IntermediateOutputPath={output};BaseIntermediateOutputPath={output}")));
            }
        }

        var outerProject = Path.Combine(_root, "outer.proj");
        new XDocument(
            new XElement("Project", new XAttribute("DefaultTargets", "Run"),
                callers,
                new XElement("Target", new XAttribute("Name", "Run"),
                    new XElement("MSBuild",
                        new XAttribute("Projects", "@(Caller)"),
                        new XAttribute("Targets", "CopyFilesToOutputDirectory"),
                        new XAttribute("BuildInParallel", "true")))))
            .Save(outerProject);

        var dotnet = Environment.GetEnvironmentVariable("DOTNET_HOST_PATH");
        var start = new ProcessStartInfo(string.IsNullOrEmpty(dotnet) ? "dotnet" : dotnet)
        {
            WorkingDirectory = _root,
            UseShellExecute = false,
            RedirectStandardOutput = true,
            RedirectStandardError = true
        };
        foreach (var inherited in new[]
        {
            "CI", "ContinuousIntegrationBuild", "GrateTestEnvironment", "GrateBuildLocalDockerImage",
            "GrateTestConfig__ApplicationDockerImage", "GrateDockerExecutable", "DesignTimeBuild"
        })
        {
            start.Environment.Remove(inherited);
        }
        start.Environment["GRATE_IMAGE_BUILD_EVENTS"] = BuildEventsPath;
        start.Environment["GRATE_IMAGE_BUILD_EXIT_CODE"] = "17";
        start.Environment["DOTNET_CLI_TELEMETRY_OPTOUT"] = "1";
        // A regression that ignores GrateDockerExecutable must still never call real Docker.
        start.Environment["PATH"] = _root + Path.PathSeparator + start.Environment["PATH"];

        foreach (var argument in new[]
        {
            "msbuild", outerProject, "-nologo", "-verbosity:quiet", "-maxCpuCount:2", "-nodeReuse:false", "-noAutoResponse",
            $"-property:GrateDockerExecutable={CreateDockerSpy()}"
        })
        {
            start.ArgumentList.Add(argument);
        }
        if (property is not null) start.ArgumentList.Add("-property:" + property);

        using var process = Process.Start(start) ?? throw new InvalidOperationException("Could not start native MSBuild.");
        var stdout = process.StandardOutput.ReadToEndAsync();
        var stderr = process.StandardError.ReadToEndAsync();
        using var cancellation = CancellationTokenSource.CreateLinkedTokenSource(TestContext.Current.CancellationToken);
        cancellation.CancelAfter(TimeSpan.FromSeconds(60));
        try
        {
            await process.WaitForExitAsync(cancellation.Token);
        }
        catch (OperationCanceledException)
        {
            if (!process.HasExited) process.Kill(entireProcessTree: true);
            await process.WaitForExitAsync(CancellationToken.None);
            var output = await stdout + await stderr;
            TestContext.Current.CancellationToken.ThrowIfCancellationRequested();
            throw new TimeoutException("Native image-build hook test timed out.\n" + output);
        }

        foreach (var sidecar in Sidecars())
        {
            var lines = File.ReadAllLines(sidecar);
            if (lines.Length == 3) _plans.Add(lines[2]);
        }
        return (process.ExitCode, await stdout + await stderr);
    }

    private string CreateDockerSpy()
    {
        var windows = OperatingSystem.IsWindows();
        var path = DockerSpyPath;
        var script = windows
            ? "@echo off\r\necho build>>\"%GRATE_IMAGE_BUILD_EVENTS%\"\r\nexit /b %GRATE_IMAGE_BUILD_EXIT_CODE%\r\n"
            : "#!/bin/sh\nprintf 'build\\n' >> \"$GRATE_IMAGE_BUILD_EVENTS\"\nexit \"$GRATE_IMAGE_BUILD_EXIT_CODE\"\n";
        File.WriteAllText(path, script, new UTF8Encoding(encoderShouldEmitUTF8Identifier: false));
        if (!OperatingSystem.IsWindows())
        {
            File.SetUnixFileMode(path, UnixFileMode.UserRead | UnixFileMode.UserWrite | UnixFileMode.UserExecute);
        }
        return path;
    }

    private string BuildEventsPath => Path.Combine(_root, "build-events.txt");
    private string DockerSpyPath => Path.Combine(_root, OperatingSystem.IsWindows() ? "docker.cmd" : "docker");

    private string[] BuildEvents() => File.Exists(BuildEventsPath) ? File.ReadAllLines(BuildEventsPath) : [];

    private string[] Sidecars() => Directory.GetFiles(Path.Combine(_root, "output"), "*.docker-build", SearchOption.AllDirectories);

    private void AssertCopyMarkers()
    {
        var markers = Directory.GetFiles(Path.Combine(_root, "copy-markers"), "*.txt");
        Assert.Equal(6, markers.Length);
        Assert.All(markers, marker => Assert.Equal(["copied"], File.ReadAllLines(marker)));
    }

    private static string RepositoryRoot([CallerFilePath] string file = "") =>
        Path.GetFullPath(Path.Combine(Path.GetDirectoryName(file)!, "../../.."));

    public void Dispose()
    {
        var generatedPlans = Path.Combine(RepositoryRoot(), "unittests", "Docker", "obj", "local-image") + Path.DirectorySeparatorChar;
        foreach (var plan in _plans)
        {
            if (Path.GetFullPath(plan).StartsWith(generatedPlans, StringComparison.Ordinal)) File.Delete(plan);
        }
        Directory.Delete(_root, recursive: true);
    }
}
