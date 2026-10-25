using System.CommandLine;
using System.Runtime.CompilerServices;
using grate.Commands;
using grate.Skills;

namespace Basic_tests.Skills;

public sealed class AgentSkillInstaller_ : IDisposable
{
    private readonly string _root = Directory.CreateTempSubdirectory("grate-skill-tests-").FullName;

    [Fact]
    public void Installs_complete_bundled_skill_for_both_agents()
    {
        var files = AgentSkillInstaller.ReadBundledFiles();
        var source = SourceSkillDirectory();
        var sourceFiles = Directory.GetFiles(source, "*", SearchOption.AllDirectories);
        Assert.Equal(sourceFiles.Length, files.Count);
        foreach (var file in sourceFiles)
        {
            Assert.Equal(File.ReadAllBytes(file), files[Path.GetRelativePath(source, file).Replace('\\', '/')]);
        }

        var destinations = AgentSkillInstaller.Install(_root, force: false);
        Assert.Equal(new[] { Destination(".agents"), Destination(".claude") }, destinations);
        foreach (var destination in destinations)
        {
            foreach (var (relativePath, content) in files)
            {
                Assert.Equal(content, File.ReadAllBytes(Path.Combine(destination, relativePath)));
            }
            if (!OperatingSystem.IsWindows())
            {
                Assert.True((File.GetUnixFileMode(Path.Combine(destination, "scripts", "verify_sqlite.sh")) & UnixFileMode.UserExecute) != 0);
            }
        }
    }

    [Fact]
    public void Installing_identical_skill_is_a_no_op()
    {
        AgentSkillInstaller.Install(_root, force: false);
        var file = Path.Combine(Destination(".agents"), "SKILL.md");
        var timestamp = new DateTime(2020, 1, 1, 0, 0, 0, DateTimeKind.Utc);
        File.SetLastWriteTimeUtc(file, timestamp);

        AgentSkillInstaller.Install(_root, force: false);

        Assert.Equal(timestamp, File.GetLastWriteTimeUtc(file));
    }

    [Fact]
    public void Accepts_project_root_with_trailing_directory_separator()
    {
        AgentSkillInstaller.Install(_root + Path.DirectorySeparatorChar, force: false);

        Assert.True(File.Exists(Path.Combine(Destination(".agents"), "SKILL.md")));
    }

    [Fact]
    public void Conflict_in_second_agent_preserves_both_destinations()
    {
        Directory.CreateDirectory(Destination(".claude"));
        var file = Path.Combine(Destination(".claude"), "SKILL.md");
        File.WriteAllText(file, "User's own skill");

        Assert.Throws<IOException>(() => AgentSkillInstaller.Install(_root, force: false));

        Assert.Equal("User's own skill", File.ReadAllText(file));
        Assert.False(Directory.Exists(Path.Combine(_root, ".agents")));
    }

    [Fact]
    public void Force_replaces_only_use_grate_and_removes_stale_files()
    {
        AgentSkillInstaller.Install(_root, force: false);
        var customFile = Path.Combine(Destination(".agents"), "scripts", "obsolete.py");
        File.WriteAllText(customFile, "old script");
        var modified = Path.Combine(Destination(".claude"), "SKILL.md");
        File.WriteAllText(modified, "Local edit");
        var neighbor = Path.Combine(_root, ".agents", "skills", "another-skill", "SKILL.md");
        Directory.CreateDirectory(Path.GetDirectoryName(neighbor)!);
        File.WriteAllText(neighbor, "Keep me");

        Assert.Throws<IOException>(() => AgentSkillInstaller.Install(_root, force: false));
        Assert.Equal("Local edit", File.ReadAllText(modified));
        AgentSkillInstaller.Install(_root, force: true);

        Assert.Equal(AgentSkillInstaller.ReadBundledFiles()["SKILL.md"], File.ReadAllBytes(modified));
        Assert.False(File.Exists(customFile));
        Assert.Equal("Keep me", File.ReadAllText(neighbor));
    }

    [Fact]
    public void Does_not_follow_agent_directory_symlinks_even_with_force()
    {
        if (OperatingSystem.IsWindows()) Assert.Skip("Creating symlinks can require Windows developer mode or elevation.");
        var outside = Directory.CreateDirectory(Path.Combine(_root, "elsewhere")).FullName;
        Directory.CreateSymbolicLink(Path.Combine(_root, ".agents"), outside);

        Assert.Throws<IOException>(() => AgentSkillInstaller.Install(_root, force: true));

        Assert.Empty(Directory.GetFileSystemEntries(outside));
        Assert.False(Directory.Exists(Path.Combine(_root, ".claude")));
    }

    [Fact]
    public void Does_not_replace_links_inside_existing_skill()
    {
        if (OperatingSystem.IsWindows()) Assert.Skip("Creating symlinks can require Windows developer mode or elevation.");
        AgentSkillInstaller.Install(_root, force: false);
        var outside = Path.Combine(_root, "outside.txt");
        File.WriteAllText(outside, "Keep me");
        File.CreateSymbolicLink(Path.Combine(Destination(".claude"), "custom.txt"), outside);

        Assert.Throws<IOException>(() => AgentSkillInstaller.Install(_root, force: true));

        Assert.Equal("Keep me", File.ReadAllText(outside));
    }

    [Fact]
    public void Local_scope_finds_repository_root_from_nested_directory()
    {
        File.WriteAllText(Path.Combine(_root, ".git"), "gitdir: worktree pointer");
        var nested = Directory.CreateDirectory(Path.Combine(_root, "src", "project")).FullName;

        Assert.Equal(_root, AgentSkillInstaller.ResolveRoot(true, false, null, nested, "unused"));
        Assert.Equal(Path.Combine(nested, "custom"), AgentSkillInstaller.ResolveRoot(true, false, "custom", nested, "unused"));
    }

    [Fact]
    public void Local_scope_outside_repository_uses_current_directory()
    {
        Assert.Equal(_root, AgentSkillInstaller.ResolveRoot(true, false, null, _root, "unused"));
    }

    [Fact]
    public void Global_scope_uses_home_independently_of_working_directory()
    {
        var home = Path.Combine(_root, "fake-home");
        var root = AgentSkillInstaller.ResolveRoot(false, true, null, "/unused", home);
        AgentSkillInstaller.Install(root, force: false);

        Assert.True(File.Exists(Path.Combine(home, ".agents", "skills", "use-grate", "SKILL.md")));
        Assert.True(File.Exists(Path.Combine(home, ".claude", "skills", "use-grate", "SKILL.md")));
        Assert.False(Directory.Exists(Path.Combine(_root, ".agents")));
    }

    [Theory]
    [InlineData(false, false, null)]
    [InlineData(true, true, null)]
    [InlineData(false, true, "project")]
    public void Rejects_ambiguous_or_incompatible_scopes(bool local, bool global, string? path)
    {
        Assert.Throws<ArgumentException>(() => AgentSkillInstaller.ResolveRoot(local, global, path, _root, _root));
    }

    [Fact]
    public async Task Install_command_works_without_database_configuration()
    {
        var root = new RootCommand();
        root.Subcommands.Add(new SkillsCommand());
        using var output = new StringWriter();
        using var error = new StringWriter();

        var exitCode = await root.Parse(["skills", "install", "--local", "--path", _root])
            .InvokeAsync(new InvocationConfiguration { Output = output, Error = error }, TestContext.Current.CancellationToken);

        Assert.Equal(0, exitCode);
        Assert.Equal("", error.ToString());
        Assert.True(File.Exists(Path.Combine(Destination(".agents"), "SKILL.md")));
        Assert.True(File.Exists(Path.Combine(Destination(".claude"), "scripts", "verify_sqlite.cs")));
    }

    [Fact]
    public async Task Invalid_install_command_fails_without_creating_agent_directories()
    {
        var root = new RootCommand();
        root.Subcommands.Add(new SkillsCommand());
        using var error = new StringWriter();
        var exitCode = await root.Parse(["skills", "install", "--path", _root])
            .InvokeAsync(new InvocationConfiguration { Error = error }, TestContext.Current.CancellationToken);

        Assert.Equal(1, exitCode);
        Assert.Contains("Specify exactly one", error.ToString());
        Assert.False(Directory.Exists(Path.Combine(_root, ".agents")));
    }

    private string Destination(string agent) => Path.Combine(_root, agent, "skills", "use-grate");
    private static string SourceSkillDirectory([CallerFilePath] string file = "") =>
        Path.GetFullPath(Path.Combine(Path.GetDirectoryName(file)!, "../../../skills/use-grate"));

    public void Dispose() => Directory.Delete(_root, recursive: true);
}
