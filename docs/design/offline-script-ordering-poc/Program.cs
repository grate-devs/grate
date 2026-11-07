using System.Text.Json;

if (args.Length != 1)
{
    Console.Error.WriteLine("Usage: OfflineScriptOrdering <sql-root>");
    return 2;
}

try
{
    var options = new JsonSerializerOptions(JsonSerializerDefaults.Web) { WriteIndented = true };
    Console.WriteLine(JsonSerializer.Serialize(new { Scripts = BuildPlan(args[0]) }, options));
    return 0;
}
catch (Exception error) when (error is InvalidDataException or IOException or UnauthorizedAccessException)
{
    Console.Error.WriteLine(error.Message);
    return 1;
}

static List<PlannedScript> BuildPlan(string root)
{
    if (!Directory.Exists(root))
        throw new InvalidDataException($"SQL root does not exist: {root}");

    var definitions = new Dictionary<SqlName, string>();
    var scripts = new List<SqlScript>();
    foreach (var folder in new[] { "functions", "views" })
    {
        var directory = Path.Combine(root, folder);
        if (!Directory.Exists(directory))
            continue;
        if (Directory.EnumerateDirectories(directory).Any())
            throw new InvalidDataException($"{folder}: subfolders are outside the prototype scope.");

        var files = Directory.EnumerateFiles(directory)
            .Where(file => Path.GetExtension(file) == ".sql")
            .OrderBy(Path.GetFileName, StringComparer.Ordinal);
        foreach (var file in files)
        {
            var path = $"{folder}/{Path.GetFileName(file)}";
            var script = SqlScript.Read(file, path, expectView: folder == "views");
            if (!definitions.TryAdd(script.Defines, path))
                throw new InvalidDataException($"Duplicate definition of {script.Defines}: {definitions[script.Defines]}, {path}");
            scripts.Add(script);
        }
    }

    if (scripts.Count == 0)
        throw new InvalidDataException("No candidate .sql files in functions or views.");

    var candidatePaths = scripts.Select(script => script.Path).ToHashSet(StringComparer.Ordinal);
    var pending = new List<PlannedScript>();
    foreach (var script in scripts)
    {
        var dependencies = new List<Dependency>();
        var outsideReferences = new List<SqlName>();
        foreach (var reference in script.References)
        {
            if (!definitions.TryGetValue(reference, out var prerequisite))
                outsideReferences.Add(reference);
            else if (script.Declarations is null)
                dependencies.Add(new(prerequisite, "inferred", reference));
        }

        foreach (var prerequisite in script.Declarations ?? [])
        {
            if (!candidatePaths.Contains(prerequisite))
                throw new InvalidDataException($"{script.Path}: declared dependency '{prerequisite}' is outside the planned group.");
            dependencies.Add(new(prerequisite, "declared", null));
        }

        pending.Add(new(script.Path, script.Defines, dependencies, outsideReferences));
    }

    // Reconsider all remaining files after each choice so newly ready files keep their original priority.
    var ordered = new List<PlannedScript>();
    var emitted = new HashSet<string>(StringComparer.Ordinal);
    while (pending.Count > 0)
    {
        var next = pending.FindIndex(script => script.Dependencies.All(dependency => emitted.Contains(dependency.Path)));
        if (next < 0)
            throw new InvalidDataException($"Dependency cycle: {FindCycle(pending)}");
        var script = pending[next];
        ordered.Add(script);
        emitted.Add(script.Path);
        pending.RemoveAt(next);
    }
    return ordered;
}

static string FindCycle(List<PlannedScript> pending)
{
    var byPath = pending.ToDictionary(script => script.Path, StringComparer.Ordinal);
    var path = pending[0].Path;
    var visited = new List<string>();
    while (!visited.Contains(path, StringComparer.Ordinal))
    {
        visited.Add(path);
        path = byPath[path].Dependencies.First(dependency => byPath.ContainsKey(dependency.Path)).Path;
    }
    return string.Join(" -> ", visited.SkipWhile(step => step != path).Append(path));
}

sealed record PlannedScript(string Path, SqlName Defines, List<Dependency> Dependencies, List<SqlName> OutsideReferences);
sealed record Dependency(string Path, string Source, SqlName? Reference);
