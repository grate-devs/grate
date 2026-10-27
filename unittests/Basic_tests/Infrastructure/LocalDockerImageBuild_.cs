using System.Diagnostics;
using System.Globalization;
using System.Runtime.CompilerServices;
using System.Text;
using System.Xml.Linq;

namespace Basic_tests.Infrastructure;

public sealed class LocalDockerImageBuild_ : IDisposable
{
    private readonly string _root = Directory.CreateTempSubdirectory("grate image build tests-").FullName;

    [Fact]
    public async Task Builds_once_before_all_projects_and_frameworks_start_their_tests()
    {
        var result = await BuildCallers(expectImageBuild: true);

        Assert.True(result.ExitCode == 0, result.Output);
        Assert.Equal(["build"], BuildEvents());
        AssertTestMarkers(6);
    }

    [Theory]
    [InlineData("CI")]
    [InlineData("ContinuousIntegrationBuild")]
    public async Task CI_builds_do_not_build_the_local_image(string ciProperty)
    {
        var result = await BuildCallers(expectImageBuild: false, property: $"{ciProperty}=true");

        Assert.True(result.ExitCode == 0, result.Output);
        Assert.Empty(BuildEvents());
        AssertTestMarkers(6);
    }

    [Fact]
    public async Task An_explicit_application_image_does_not_build_the_local_image()
    {
        var result = await BuildCallers(
            expectImageBuild: false, property: "GrateTestConfig__ApplicationDockerImage=custom:tests");

        Assert.True(result.ExitCode == 0, result.Output);
        Assert.Empty(BuildEvents());
        AssertTestMarkers(6);
    }

    [Fact]
    public async Task A_failed_image_build_prevents_the_tests_from_starting()
    {
        var result = await BuildCallers(expectImageBuild: true, dockerExitCode: 17);

        Assert.NotEqual(0, result.ExitCode);
        Assert.Contains("17", result.Output);
        Assert.NotEmpty(BuildEvents());
        AssertTestMarkers(0);
    }

    private async Task<(int ExitCode, string Output)> BuildCallers(
        bool expectImageBuild, string? property = null, int dockerExitCode = 0)
    {
        var markers = Directory.CreateDirectory(Path.Combine(_root, "test-markers")).FullName;
        var emptySources = Directory.CreateDirectory(Path.Combine(_root, "empty-sources")).FullName;
        var targets = Path.Combine(RepositoryRoot(), "unittests", "Docker", "IncludeTests.targets");

        foreach (var name in new[] { "caller-a", "caller-b" })
        {
            new XDocument(
                new XElement("Project",
                    new XAttribute("DefaultTargets", "_MTPBuild"),
                    new XElement("PropertyGroup",
                        new XElement("ProjectToIncludeTestsFrom", emptySources),
                        new XElement("AssemblyName", name),
                        new XElement("BuildEventsFile", BuildEventsPath),
                        new XElement("CI", "false"),
                        new XElement("ContinuousIntegrationBuild", "false")),
                    new XElement("Import", new XAttribute("Project", targets)),
                    new XElement("Target", new XAttribute("Name", "_MTPBuild"),
                        new XElement("Error",
                            new XAttribute("Condition", "'$(ExpectLocalImageBuild)' == 'true' and !Exists('$(BuildEventsFile)')"),
                            new XAttribute("Text", "Tests started before the local image build.")),
                        new XElement("WriteLinesToFile",
                            new XAttribute("File", Path.Combine(markers, "$(MSBuildProjectName)-$(TargetFramework)-$(RuntimeIdentifier).txt")),
                            new XAttribute("Lines", "test"),
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
                        new XAttribute("Targets", "_MTPBuild"),
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
        start.Environment["GRATE_IMAGE_BUILD_EXIT_CODE"] = dockerExitCode.ToString(CultureInfo.InvariantCulture);
        start.Environment["DOTNET_CLI_TELEMETRY_OPTOUT"] = "1";
        // A regression that ignores GrateDockerExecutable must still never call real Docker.
        start.Environment["PATH"] = _root + Path.PathSeparator + start.Environment["PATH"];

        foreach (var argument in new[]
        {
            "msbuild", outerProject, "-nologo", "-verbosity:quiet", "-maxCpuCount:2", "-nodeReuse:false", "-noAutoResponse",
            $"-property:GrateDockerExecutable={CreateDockerSpy()}",
            $"-property:ExpectLocalImageBuild={expectImageBuild.ToString().ToLowerInvariant()}"
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

        return (process.ExitCode, await stdout + await stderr);
    }

    private string CreateDockerSpy()
    {
        var windows = OperatingSystem.IsWindows();
        var path = Path.Combine(_root, windows ? "docker.cmd" : "docker");
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

    private string[] BuildEvents() => File.Exists(BuildEventsPath) ? File.ReadAllLines(BuildEventsPath) : [];

    private void AssertTestMarkers(int count)
    {
        var markers = Directory.GetFiles(Path.Combine(_root, "test-markers"), "*.txt");
        Assert.Equal(count, markers.Length);
        Assert.All(markers, marker => Assert.Equal(["test"], File.ReadAllLines(marker)));
    }

    private static string RepositoryRoot([CallerFilePath] string file = "") =>
        Path.GetFullPath(Path.Combine(Path.GetDirectoryName(file)!, "../../.."));

    public void Dispose() => Directory.Delete(_root, recursive: true);
}
