using System.CommandLine;
using grate.Skills;

namespace grate.Commands;

internal sealed class SkillsCommand : Command
{
    public SkillsCommand() : base("skills", "Install grate's bundled agent skill for Codex and Claude Code.")
    {
        var local = new Option<bool>("--local") { Description = "Install in the current repository, or current directory outside a repository." };
        var global = new Option<bool>("--global") { Description = "Install in the current user's home directory." };
        var path = new Option<string?>("--path") { Description = "Explicit project root for --local (instead of repository discovery)." };
        var force = new Option<bool>("--force") { Description = "Replace existing use-grate directories, including local edits and extra files." };
        var install = new Command("install", "Copy the bundled use-grate skill into .agents/skills and .claude/skills.")
        {
            Options = { local, global, path, force }
        };
        install.SetAction((result, _) =>
        {
            try
            {
                var root = AgentSkillInstaller.ResolveRoot(result.GetValue(local), result.GetValue(global),
                    result.GetValue(path), Directory.GetCurrentDirectory(),
                    Environment.GetFolderPath(Environment.SpecialFolder.UserProfile));
                foreach (var destination in AgentSkillInstaller.Install(root, result.GetValue(force)))
                {
                    result.InvocationConfiguration.Output.WriteLine($"Skill available: {destination}");
                }
                return Task.FromResult(0);
            }
            catch (Exception error) when (error is ArgumentException or IOException or UnauthorizedAccessException or InvalidOperationException)
            {
                result.InvocationConfiguration.Error.WriteLine($"Skill installation failed: {error.Message}");
                return Task.FromResult(1);
            }
        });
        Subcommands.Add(install);
    }
}
