namespace grate.Skills;

internal static class AgentSkillInstaller
{
    private const string ResourcePrefix = "grate.skills.use-grate/";

    internal static string ResolveRoot(bool local, bool global, string? path, string currentDirectory, string homeDirectory)
    {
        if (local == global)
        {
            throw new ArgumentException("Specify exactly one of --local or --global.");
        }
        if (global)
        {
            if (path is not null) throw new ArgumentException("--path can only be used with --local.");
            if (string.IsNullOrWhiteSpace(homeDirectory)) throw new InvalidOperationException("Cannot locate the current user's home directory.");
            return Path.GetFullPath(homeDirectory);
        }
        if (path is not null) return Path.GetFullPath(path, currentDirectory);
        for (var directory = new DirectoryInfo(currentDirectory); directory is not null; directory = directory.Parent)
        {
            // .git can be a directory or a worktree's pointer file.
            if (Path.Exists(Path.Combine(directory.FullName, ".git"))) return directory.FullName;
        }
        return Path.GetFullPath(currentDirectory);
    }

    internal static IReadOnlyDictionary<string, byte[]> ReadBundledFiles()
    {
        var assembly = typeof(AgentSkillInstaller).Assembly;
        var files = new Dictionary<string, byte[]>(StringComparer.Ordinal);
        foreach (var name in assembly.GetManifestResourceNames().Where(name => name.StartsWith(ResourcePrefix, StringComparison.Ordinal)))
        {
            var relativePath = name[ResourcePrefix.Length..].Replace('\\', '/');
            if (relativePath.Split('/').Any(part => part is "" or "." or ".."))
            {
                throw new InvalidOperationException($"Invalid bundled skill path: {relativePath}");
            }
            using var source = assembly.GetManifestResourceStream(name)
                ?? throw new InvalidOperationException($"Cannot read bundled skill resource: {name}");
            using var content = new MemoryStream();
            source.CopyTo(content);
            files.Add(relativePath, content.ToArray());
        }
        if (!files.ContainsKey("SKILL.md")) throw new InvalidOperationException("This grate build has no bundled use-grate skill.");
        return files;
    }

    internal static IReadOnlyList<string> Install(string root, bool force)
    {
        root = Path.TrimEndingDirectorySeparator(Path.GetFullPath(root));
        var files = ReadBundledFiles();
        var destinations = new[] { ".agents", ".claude" }
            .Select(agent => Path.Combine(root, agent, "skills", "use-grate")).ToArray();

        // Check both destinations before modifying either, so an ordinary conflict cannot leave a partial install.
        foreach (var destination in destinations)
        {
            RejectLinksInPath(destination, root);
            if (File.Exists(destination)) throw new IOException($"A file occupies {destination}.");
            if (Directory.Exists(destination))
            {
                RejectLinksInTree(destination);
                if (!force && !MatchesBundle(destination, files))
                {
                    throw new IOException($"Existing skill differs at {destination}. Back up local changes, then use --force to replace this skill directory.");
                }
            }
        }

        foreach (var destination in destinations)
        {
            if (Directory.Exists(destination) && MatchesBundle(destination, files)) continue;
            ReplaceDirectory(destination, files);
        }
        return destinations;
    }

    private static bool MatchesBundle(string directory, IReadOnlyDictionary<string, byte[]> files)
    {
        var existing = Directory.GetFiles(directory, "*", SearchOption.AllDirectories);
        return existing.Length == files.Count && existing.All(file =>
            files.TryGetValue(Path.GetRelativePath(directory, file).Replace('\\', '/'), out var expected)
            && File.ReadAllBytes(file).AsSpan().SequenceEqual(expected));
    }

    private static void RejectLinksInPath(string path, string root)
    {
        // The explicitly selected root may use an OS alias such as /tmp on macOS.
        // Reject redirection inside the agent directories, rather than those root aliases.
        for (var item = new DirectoryInfo(path); item is not null && item.FullName != root; item = item.Parent)
        {
            if (item.LinkTarget is not null || (item.Exists && (item.Attributes & FileAttributes.ReparsePoint) != 0))
            {
                throw new IOException($"Skill installation does not follow symbolic links or reparse points: {item.FullName}");
            }
        }
    }

    private static void RejectLinksInTree(string directory)
    {
        foreach (var entry in new DirectoryInfo(directory).EnumerateFileSystemInfos())
        {
            if (entry.LinkTarget is not null || (entry.Attributes & FileAttributes.ReparsePoint) != 0)
            {
                throw new IOException($"Skill installation does not replace symbolic links or reparse points: {entry.FullName}");
            }
            if (entry is DirectoryInfo child) RejectLinksInTree(child.FullName);
        }
    }

    private static void ReplaceDirectory(string destination, IReadOnlyDictionary<string, byte[]> files)
    {
        var parent = Directory.CreateDirectory(Path.GetDirectoryName(destination)!).FullName;
        var staging = Path.Combine(parent, $".use-grate-{Guid.NewGuid():N}");
        var backup = staging + ".previous";
        Directory.CreateDirectory(staging);
        try
        {
            foreach (var (relativePath, contents) in files)
            {
                var file = Path.Combine(staging, relativePath.Replace('/', Path.DirectorySeparatorChar));
                Directory.CreateDirectory(Path.GetDirectoryName(file)!);
                File.WriteAllBytes(file, contents);
            }
            if (Directory.Exists(destination)) Directory.Move(destination, backup);
            try
            {
                Directory.Move(staging, destination);
            }
            catch
            {
                if (Directory.Exists(backup)) Directory.Move(backup, destination);
                throw;
            }
            if (Directory.Exists(backup)) Directory.Delete(backup, recursive: true);
        }
        finally
        {
            if (Directory.Exists(staging)) Directory.Delete(staging, recursive: true);
        }
    }
}
