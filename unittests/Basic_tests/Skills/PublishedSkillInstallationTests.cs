using System.Diagnostics;
using System.Runtime.CompilerServices;
using System.Text.Json;

namespace Basic_tests.Skills;

// Dedicated CI builds real distributions and supplies their invocation; ordinary unit runs skip these cases.
public sealed class PublishedSkillInstallationTests(ITestOutputHelper output)
{
    public static bool IsDistributionRun => Environment.GetEnvironmentVariable("GITHUB_ACTIONS") == "true"
        && !string.IsNullOrEmpty(Environment.GetEnvironmentVariable("GRATE_SKILL_TEST_COMMAND"));

    [Fact(SkipUnless = nameof(IsDistributionRun), Skip = "Runs against published distributions in the Skill installation CI job.")]
    public async Task Published_cli_installs_the_complete_skill_into_an_explicit_project()
    {
        var project = Directory.CreateTempSubdirectory("grate-published-local-").FullName;
        try
        {
            await Install("--local", "--path", project);
            AssertSkill(project);
        }
        finally
        {
            Directory.Delete(project, recursive: true);
        }
    }

    [Fact(SkipUnless = nameof(IsDistributionRun), Skip = "Runs against published distributions in the Skill installation CI job.")]
    public async Task Published_cli_installs_the_complete_skill_into_the_ci_users_home()
    {
        var home = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
        var targets = new[] { ".agents", ".claude" }
            .Select(agent => Path.Combine(home, agent, "skills", "use-grate")).ToArray();
        // Never replace or remove a pre-existing skill, even on a configured self-hosted runner.
        Assert.All(targets, target => Assert.False(Path.Exists(target), $"CI skill target already exists: {target}"));
        try
        {
            await Install("--global");
            AssertSkill(home);
        }
        finally
        {
            foreach (var target in targets)
                if (Directory.Exists(target)) Directory.Delete(target, recursive: true);
        }
    }

    private async Task Install(params string[] arguments)
    {
        var command = JsonSerializer.Deserialize<string[]>(Environment.GetEnvironmentVariable("GRATE_SKILL_TEST_COMMAND")!)!;
        var start = new ProcessStartInfo(command[0])
        {
            WorkingDirectory = Environment.GetEnvironmentVariable("GRATE_SKILL_TEST_WORKING_DIRECTORY")!,
            UseShellExecute = false, RedirectStandardOutput = true, RedirectStandardError = true
        };
        foreach (var argument in command.Skip(1).Concat(["skills", "install"]).Concat(arguments))
            start.ArgumentList.Add(argument);
        using var process = Process.Start(start) ?? throw new InvalidOperationException("Could not start published CLI.");
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
            TestContext.Current.CancellationToken.ThrowIfCancellationRequested();
            throw new TimeoutException("Published CLI installation timed out.");
        }
        output.WriteLine(await stdout + await stderr);
        Assert.Equal(0, process.ExitCode);
    }

    private static void AssertSkill(string root, [CallerFilePath] string source = "")
    {
        var canonical = Path.GetFullPath(Path.Combine(Path.GetDirectoryName(source)!, "../../../docs/skills/use-grate"));
        var expected = Directory.GetFiles(canonical, "*", SearchOption.AllDirectories);
        foreach (var agent in new[] { ".agents", ".claude" })
        {
            var destination = Path.Combine(root, agent, "skills", "use-grate");
            Assert.Equal(expected.Length, Directory.GetFiles(destination, "*", SearchOption.AllDirectories).Length);
            foreach (var file in expected)
                Assert.Equal(File.ReadAllBytes(file), File.ReadAllBytes(Path.Combine(destination, Path.GetRelativePath(canonical, file))));
            Assert.False(Directory.Exists(Path.Combine(destination, "scripts")));
        }
    }
}
